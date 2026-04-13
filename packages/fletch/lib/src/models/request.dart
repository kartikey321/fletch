import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fletch/fletch.dart';
import 'package:get_it/get_it.dart';
import 'package:meta/meta.dart';
import 'package:mime/mime.dart';

final _secureRandom = Random.secure();

String _randomToken(int byteLength) {
  final bytes =
      List<int>.generate(byteLength, (_) => _secureRandom.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Represents an incoming HTTP request with convenient accessors for
/// common data like headers, query parameters, request body, and session.
///
/// Request objects are created by the framework and passed to route handlers.
/// The request body stream can only be consumed once, so repeated reads of
/// [body] or [formData] will return the cached value.
///
/// ## Example
///
/// ```dart
/// app.post('/users', (req, res) async {
///   // Access path parameters
///   final id = req.params['id'];
///
///   // Access query parameters
///   final filter = req.query['filter'];
///
///  // Access request body
///   final data = await req.body;
///
///   // Access session
///   req.session['userId'] = id;
/// });
/// ```
class Request {
  /// The underlying Dart HttpRequest.
  final HttpRequest httpRequest;

  /// Unique identifier for this request.
  ///
  /// Echoes the incoming `x-request-id` / `x-correlation-id` header when
  /// present; otherwise a random `req_*` token generated on first access.
  String get requestId => _requestId ??= _generateRequestId();
  String? _requestId;

  /// Path parameters extracted from the route pattern.
  ///
  /// For route `/users/:id`, accessing `/users/123` gives `params['id'] == '123'`.
  Map<String, String> params = {};

  /// Query parameters from the URL.
  ///
  /// For URL `/search?q=dart&page=2`:
  /// - `query['q']` returns `'dart'`
  /// - `query['page']` returns `'2'`
  Map<String, String>? _query;
  Map<String, String> get query => _query ??= httpRequest.uri.queryParameters;

  /// Session for this request.
  ///
  /// Access session data with:
  /// ```dart
  /// req.session['key'] = 'value';
  /// final value = req.session['key'];
  /// ```
  ///
  /// The session is lazy: no session cookie is emitted and no store I/O
  /// occurs unless this getter is actually accessed during the request.
  /// Returns the session for this request.
  ///
  /// The [Session] object (and its internal data map) is created on first
  /// access — routes that never read or write session data pay zero cost.
  Session get session {
    sessionTouched = true;
    if (_sessionInstance != null) return _sessionInstance!;
    // Generate a new session ID only on first access — routes that never
    // touch the session pay zero Random.secure() cost.
    _sessionId ??= _generateSessionId();
    return _sessionInstance = Session(_sessionId!, store: _sessionStoreRef);
  }

  // Backing state for the lazy session.
  // null for brand-new sessions until first access; non-null for returning
  // visitors (ID extracted from the verified cookie).
  String? _sessionId;
  final SessionStore? _sessionStoreRef;
  Session? _sessionInstance;

  // Internal DI scope — the app-level GetIt instance, or a scoped
  // GetIt.asNewInstance() for IsolatedContainers.
  final GetIt _scope;

  /// Resolves a registered service of type [T] from the DI scope.
  ///
  /// Prefer this over [container] for new code:
  ///
  /// ```dart
  /// app.get('/users', (req, res) async {
  ///   final svc = req.resolve<UserService>();
  ///   res.json(await svc.list());
  /// });
  /// ```
  ///
  /// For [IsolatedContainer] modules the resolution uses the module's own
  /// scoped container so registrations don't bleed across mount points.
  T resolve<T extends Object>({String? instanceName}) =>
      _scope.get<T>(instanceName: instanceName);

  /// The raw GetIt dependency injection container for this request.
  ///
  /// Deprecated: use [resolve] instead.
  /// `req.container.get<T>()` → `req.resolve<T>()`
  ///
  /// Will be removed in v3.0.0.
  @Deprecated(
    'Use req.resolve<T>() instead. '
    'req.container exposes GetIt as a framework detail and will be removed in v3.0.0.',
  )
  GetIt get container => _scope;

  /// Maximum allowed request body size in bytes (default: 10MB).
  final int maxBodySize;

  /// Maximum allowed file upload size in bytes (default: 100MB).
  final int maxFileSize;

  /// Session signer for verifying cookie signatures.
  final SessionSigner? sessionSigner;

  Object? _parsedBody;
  Future<Uint8List>? _bodyBytesFuture;
  _FormDataPayload? _multipartPayload;
  Map<String, dynamic>? _formDataCache;
  final bool _isSessionNew;

  /// `true` once [session] has been accessed during this request lifecycle.
  /// Used by the framework to skip session I/O on routes that never touch it.
  /// Framework-internal — do not use in application code.
  @internal
  bool sessionTouched = false;

  /// `true` when the incoming request carried an `x-request-id` or
  /// `x-correlation-id` header.  The framework uses this flag (set once at
  /// construction) to echo the correlation header on the response without
  /// re-reading [HttpHeaders] a second time inside `processRequest`.
  ///
  /// Only valid before the route handler runs (the backing field is lazily
  /// populated afterwards). Framework-internal — do not use in handlers.
  @internal
  bool get hasIncomingRequestId => _requestId != null;

  /// Loads the session from the store without marking [sessionTouched].
  /// Used by the framework for returning-visitor pre-load; does not count
  /// as application code accessing the session.
  @internal
  Future<void> preloadSession() {
    // Only called for returning visitors — _sessionId is always non-null here
    // because it was extracted from the verified session cookie.
    final s = _sessionInstance ??= Session(_sessionId!, store: _sessionStoreRef);
    return s.load();
  }

  // Lazily parsed — null until first access of [cookies].
  List<Cookie>? _cookiesCache;

  /// Parsed cookies from the Cookie header.
  ///
  /// Parsed on first access; routes that never read cookies pay zero cost.
  List<Cookie> get cookies => _cookiesCache ??= _parseCookies();

  /// Allows framework or middleware to pre-populate the cookies list.
  set cookies(List<Cookie> value) => _cookiesCache = value;

  static final _semiColonSplit = RegExp(r';\s*');

  List<Cookie> _parseCookies() {
    final header = httpRequest.headers.value(HttpHeaders.cookieHeader);
    if (header == null || header.isEmpty) return const [];
    final result = <Cookie>[];
    for (final pair in header.split(_semiColonSplit)) {
      if (pair.isEmpty) continue;
      final eqIdx = pair.indexOf('=');
      if (eqIdx <= 0) continue;
      final name = pair.substring(0, eqIdx).trim();
      if (name.isEmpty) continue;
      final value = pair.substring(eqIdx + 1).trim();
      try {
        result.add(Cookie(name, Uri.decodeComponent(value)));
      } catch (_) {
        // Skip cookies with malformed percent-encoding.
      }
    }
    return result;
  }

  Request(
    this.httpRequest,
    String? sessionId,
    String? requestId,
    GetIt scope, {
    bool isSessionNew = false,
    SessionStore? sessionStore,
    /// Provide a pre-built [Session] to share across scoped sub-requests
    /// (e.g. IsolatedContainer). When given, [sessionId] and [sessionStore]
    /// are ignored for session construction.
    Session? existingSession,
    this.maxBodySize = 10 * 1024 * 1024,
    this.maxFileSize = 100 * 1024 * 1024,
    this.sessionSigner,
  })  : _scope = scope,
        _isSessionNew = isSessionNew,
        _sessionId = existingSession?.id ?? sessionId,
        _requestId = requestId,
        _sessionStoreRef = sessionStore,
        _sessionInstance = existingSession;

  /// HTTP method (GET, POST, PUT, DELETE, etc.).
  String get method => httpRequest.method;

  /// Request URI with path and query parameters.
  Uri get uri => httpRequest.uri;

  /// HTTP request headers.
  HttpHeaders get headers => httpRequest.headers;

  /// Returns the parsed request body.
  ///
  /// Body is parsed based on Content-Type header:
  /// - `application/json` → Decoded JSON (Map or List)
  /// - `application/x-www-form-urlencoded` → Map(String, String)
  /// - `text/*` → String
  /// - Other → Uint8List (raw bytes)
  ///
  /// The body stream is consumed only once. Subsequent calls return cached value.
  ///
  /// ## Example
  ///
  /// ```dart
  /// app.post('/api/data', (req, res) async {
  ///   final body = await req.body;
  ///
  ///   if (body is Map) {
  ///     final name = body['name'];
  ///     res.json({'received': name});
  ///   }
  /// });
  /// ```
  ///
  /// Returns `null` if body is empty.
  Future<Object?> get body async {
    if (_parsedBody != null) {
      return _parsedBody;
    }

    final contentType = headers.contentType?.mimeType ?? '';
    final bodyBytes = await _ensureBodyBytes();

    if (bodyBytes.isEmpty) {
      _parsedBody = null;
      return _parsedBody;
    }

    if (contentType == ContentType.json.mimeType ||
        contentType.endsWith('+json')) {
      _parsedBody = jsonDecode(utf8.decode(bodyBytes));
      return _parsedBody;
    }

    if (contentType == 'application/x-www-form-urlencoded') {
      _parsedBody = Uri.splitQueryString(utf8.decode(bodyBytes));
      return _parsedBody;
    }

    if (contentType.startsWith('text/')) {
      _parsedBody = utf8.decode(bodyBytes);
      return _parsedBody;
    }

    _parsedBody = bodyBytes;
    return _parsedBody;
  }

  /// Returns a merged view of multipart form fields and uploaded files.
  ///
  /// Keys pointing to files expose `List<MultipartFile>` while standard
  /// fields expose `String` values. For non-multipart requests this resolves
  /// to an empty map.
  Future<Map<String, dynamic>> get formData async {
    if (_formDataCache != null) {
      return _formDataCache!;
    }

    final payload = await _ensureMultipartPayload();
    final combined = <String, dynamic>{};
    combined.addAll(payload.fields);
    combined.addAll(payload.files);
    _formDataCache = Map.unmodifiable(combined);
    return _formDataCache!;
  }

  /// Creates a request wrapper, bootstrapping session state from the incoming
  /// cookie (or generating a new session identifier when absent).
  ///
  /// If [sessionSigner] is provided, session cookies will be verified using
  /// HMAC-SHA256. Invalid signatures will be treated as if no session exists.
  factory Request.from(
    HttpRequest httpRequest, {
    required GetIt container,
    int maxBodySize = 10 * 1024 * 1024,
    int maxFileSize = 100 * 1024 * 1024,
    SessionSigner? sessionSigner,
    SessionStore? sessionStore,
  }) {
    String? rawSessionId;
    String? sessionId;
    bool isSessionNew = false;
    
    // Extract session cookie by splitting on ';' and checking each part
    // for an exact name match — prevents prefix-confusion attacks where a
    // cookie like "evilfletch.sid=x;fletch.sid=good" would otherwise return
    // the wrong value with a simple indexOf approach.
    final cookieHeaders = httpRequest.headers[HttpHeaders.cookieHeader];
    outer:
    if (cookieHeaders != null) {
      for (final header in cookieHeaders) {
        for (final part in header.split(';')) {
          final token = part.trimLeft();
          final eqIdx = token.indexOf('=');
          if (eqIdx <= 0) continue;
          if (token.substring(0, eqIdx) == _sessionCookieName) {
            rawSessionId = token.substring(eqIdx + 1);
            break outer;
          }
        }
      }
    }

    if (rawSessionId != null) {
      if (sessionSigner != null) {
        final verifiedId = sessionSigner.verify(rawSessionId);
        if (verifiedId != null) {
          sessionId = verifiedId;
        } else {
          // Invalid signature — treat as new session; ID generated lazily.
          isSessionNew = true;
        }
      } else {
        sessionId = rawSessionId;
      }
    } else {
      // No cookie — new session; ID generated lazily on first req.session access.
      isSessionNew = true;
    }

    // Both session ID and request ID are lazy: generated only when first
    // accessed so routes that touch neither pay zero Random.secure() cost.
    final incomingRequestId = httpRequest.headers.value('x-request-id') ??
        httpRequest.headers.value('x-correlation-id');

    return Request(
      httpRequest,
      sessionId,
      incomingRequestId,
      container,
      isSessionNew: isSessionNew,
      sessionStore: sessionStore,
      maxBodySize: maxBodySize,
      maxFileSize: maxFileSize,
      sessionSigner: sessionSigner,
    );
  }

  static String _generateSessionId() => 'ses_${_randomToken(24)}';

  static String _generateRequestId() => 'req_${_randomToken(12)}';

  /// Indicates whether a fresh session identifier was generated for this
  /// request (and therefore needs to be persisted back via response cookies).
  bool get isNewSession => _isSessionNew;

  Future<Map<String, List<MultipartFile>>> get files async {
    final payload = await _ensureMultipartPayload();
    return payload.files;
  }

  // Helper method to read stream fully into a list of bytes to prevent multiple listens
  Future<List<int>> consolidateBytes(Stream<List<int>> stream,
      {int? sizeLimit}) async {
    final buffer = BytesBuilder();
    var totalSize = 0;
    final limit = sizeLimit ?? maxFileSize;

    await for (final chunk in stream) {
      totalSize += chunk.length;

      if (totalSize > limit) {
        throw HttpError(413, 'File too large');
      }

      buffer.add(chunk);
    }
    return buffer.takeBytes();
  }

  Future<Uint8List> _ensureBodyBytes() {
    final existing = _bodyBytesFuture;
    if (existing != null) {
      return existing;
    }

    final future = () async {
      final buffer = BytesBuilder();
      var totalSize = 0;
      final iterator = StreamIterator<List<int>>(httpRequest);

      try {
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          totalSize += chunk.length;

          if (totalSize > maxBodySize) {
            // Consume and discard remaining bytes to keep the socket healthy.
            while (await iterator.moveNext()) {}
            throw HttpError(413, 'Payload Too Large');
          }

          buffer.add(chunk);
        }
      } finally {
        await iterator.cancel();
      }

      return buffer.takeBytes();
    }();

    _bodyBytesFuture = future;
    return future;
  }

  Future<_FormDataPayload> _ensureMultipartPayload() async {
    if (_multipartPayload != null) {
      return _multipartPayload!;
    }

    final contentType = headers.contentType;
    if (contentType?.mimeType != 'multipart/form-data') {
      _multipartPayload = _FormDataPayload.empty;
      _formDataCache = const {};
      return _multipartPayload!;
    }

    final boundary = contentType!.parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      _multipartPayload = _FormDataPayload.empty;
      _formDataCache = const {};
      return _multipartPayload!;
    }

    final transformer = MimeMultipartTransformer(boundary);
    final bodyBytes = await _ensureBodyBytes();
    final stream = Stream<List<int>>.fromIterable(<List<int>>[bodyBytes]);
    final parts = await transformer.bind(stream).toList();

    final fieldData = <String, String>{};
    final fileData = <String, List<MultipartFile>>{};

    for (final part in parts) {
      final contentDisposition = part.headers['content-disposition'];
      if (contentDisposition == null) {
        continue;
      }

      final nameMatch =
          RegExp(r'name="([^"]*)"').firstMatch(contentDisposition);
      if (nameMatch == null) {
        continue;
      }

      final name = nameMatch.group(1)!;
      final filenameMatch =
          RegExp(r'filename="([^"]*)"').firstMatch(contentDisposition);

      if (filenameMatch != null) {
        // This is a file upload - check file size limit
        final filename = filenameMatch.group(1)!;
        final bytes = Uint8List.fromList(
            await consolidateBytes(part, sizeLimit: maxFileSize));

        final filesForField =
            fileData.putIfAbsent(name, () => <MultipartFile>[]);
        filesForField.add(
          MultipartFile.fromBytes(
            name,
            bytes,
            filename: filename,
          ),
        );
      } else {
        // Regular form field
        final bytes = Uint8List.fromList(await consolidateBytes(part));
        fieldData[name] = utf8.decode(bytes);
      }
    }

    _multipartPayload = _FormDataPayload(fieldData, fileData);
    final combined = <String, dynamic>{};
    combined.addAll(_multipartPayload!.fields);
    combined.addAll(_multipartPayload!.files);
    _formDataCache = Map.unmodifiable(combined);
    return _multipartPayload!;
  }

  static const String _sessionCookieName = 'sessionId';

  /// Public accessor for the name of the framework-managed session cookie.
  static const String sessionCookieName = _sessionCookieName;
}

/// Represents a user session with optional persistent storage.
///
/// Sessions can be backed by a [SessionStore] for persistence across
/// server restarts and multi-instance deployments.
///
/// ## Usage
/// ```dart
/// // Access session data
/// final userId = req.session['userId'];
///
/// // Set session data
/// req.session['userId'] = '123';
/// req.session['username'] = 'john';
///
/// // Session is automatically saved after request completes
/// ```
class Session {
  String _id;
  final SessionStore? _store;
  Map<String, dynamic> _data = {};
  bool _isDirty = false;
  bool _isLoaded = false;
  bool _wasRegenerated = false;

  /// The current session identifier.
  ///
  /// Changes after a call to [regenerate].
  String get id => _id;

  /// Whether [regenerate] has been called on this session.
  bool get wasRegenerated => _wasRegenerated;

  Session(String id, {SessionStore? store})
      : _id = id,
        _store = store {
    // If no store, mark as loaded since there's nothing to load
    if (store == null) {
      _isLoaded = true;
    }
  }

  /// Replaces the session ID with a new cryptographically-random value and
  /// destroys the old session record in the store.
  ///
  /// Call this after a privilege change (e.g. successful login) to prevent
  /// [session fixation attacks](https://owasp.org/www-community/attacks/Session_fixation).
  ///
  /// ```dart
  /// app.post('/login', (req, res) async {
  ///   final ok = await validateCredentials(req);
  ///   if (ok) {
  ///     await req.session.regenerate(); // invalidate old ID
  ///     req.session['userId'] = user.id;
  ///   }
  /// });
  /// ```
  Future<void> regenerate() async {
    if (_wasRegenerated) return; // idempotent
    final oldId = _id;
    _id = _randomToken(24);
    _wasRegenerated = true;
    _isDirty = true;
    if (_store != null) {
      await _store.destroy(oldId);
    }
  }

  /// Gets a value from the session.
  dynamic operator [](String key) => _data[key];

  /// Sets a value in the session and marks it as dirty.
  void operator []=(String key, dynamic value) {
    _data[key] = value;
    _isDirty = true;
  }

  /// Removes a key from the session.
  void remove(String key) {
    _data.remove(key);
    _isDirty = true;
  }

  /// Clears all session data.
  void clear() {
    _data.clear();
    _isDirty = true;
  }

  /// Returns an unmodifiable view of session data.
  Map<String, dynamic> get data => Map.unmodifiable(_data);

  /// Whether this session has unsaved changes.
  bool get isDirty => _isDirty;

  /// Loads session data from the store.
  ///
  /// This is automatically called when a request is processed.
  /// You rarely need to call this manually.
  Future<void> load() async {
    if (_store != null && !_isLoaded) {
      final loadedData = await _store.load(id);
      _data = loadedData ?? {};
      _isLoaded = true;
      _isDirty = false;
    }
  }

  /// Saves session data to the store if it has been modified.
  ///
  /// This is automatically called after a request completes.
  /// You can call it manually if you need to ensure data is persisted.
  ///
  /// Parameters:
  /// - [ttl]: Optional time-to-live for the session
  Future<void> save({Duration? ttl}) async {
    if (_store != null && _isDirty) {
      await _store.save(id, _data, ttl: ttl);
      _isDirty = false;
    }
  }

  /// Destroys this session, removing all data from the store.
  ///
  /// After calling this, the session ID becomes invalid and a new
  /// session will be created on the next request.
  Future<void> destroy() async {
    if (_store != null) {
      await _store.destroy(id);
    }
    _data.clear();
    _isDirty = false;
  }

  // Removed regenerate() method - session ID is final and can't be changed.
  // To regenerate session for security (e.g., after login), create a new
  // session by destroying the current one and letting the framework create
  // a new one on the next request.
  //
  // Example:
  //   await req.session.destroy();
  //   res.clearCookie(Request.sessionCookieName);
  //   // Next request will get a new session
}

class _FormDataPayload {
  _FormDataPayload(
      Map<String, String> fields, Map<String, List<MultipartFile>> files)
      : fields = Map.unmodifiable(Map<String, String>.from(fields)),
        files = Map.unmodifiable(
          files.map(
            (key, value) =>
                MapEntry(key, List<MultipartFile>.unmodifiable(value)),
          ),
        );

  static final _FormDataPayload empty =
      _FormDataPayload(<String, String>{}, <String, List<MultipartFile>>{});

  final Map<String, String> fields;
  final Map<String, List<MultipartFile>> files;

  bool get hasFiles => files.isNotEmpty;
  bool get isEmpty => fields.isEmpty && files.isEmpty;
}

/// Safety helpers for uploaded files.
///
/// Always prefer [sanitizedFilename] over [MultipartFile.filename] when
/// constructing file-system paths — the raw value is attacker-controlled and
/// may contain path-traversal sequences such as `../../etc/passwd`.
extension MultipartFileExtension on MultipartFile {
  /// Returns the uploaded filename with all path components stripped.
  ///
  /// Safe to use when building file-system paths.  `null` when no filename
  /// was supplied by the client.
  ///
  /// ```dart
  /// final safe = file.sanitizedFilename; // 'avatar.png', never '../secret'
  /// ```
  String? get sanitizedFilename {
    final name = filename;
    if (name == null) return null;
    // Split on both / and \ to neutralise Windows-style traversal sequences.
    final parts = name.split(RegExp(r'[/\\]'));
    final last = parts.lastWhere((p) => p.isNotEmpty, orElse: () => '');
    return last.isEmpty ? null : last;
  }
}
