import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:fletch/fletch.dart';

/// Common HTTP method constants used across the framework.
// ignore_for_file: constant_identifier_names
class RequestTypes {
  static const String GET = 'GET';
  static const String POST = 'POST';
  static const String PUT = 'PUT';
  static const String PATCH = 'PATCH';
  static const String DELETE = 'DELETE';
  static const String OPTIONS = 'OPTIONS';
  static const String HEAD = 'HEAD';
  static const List<String> allTypes = [
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS
  ];
}

/// A production-ready web framework for Dart inspired by Express.js.
///
/// Fletch provides a familiar Express-like API for building HTTP servers
/// with built-in security features, middleware support, and flexible routing.
///
/// ## Quick Start
///
/// ```dart
/// final app = Fletch();
///
/// app.get('/', (req, res) {
///   res.text('Hello World!');
/// });
///
/// await app.listen(3000);
/// ```
///
/// ## Production Setup
///
/// ```dart
/// final app = Fletch(
///   sessionSecret: Platform.environment['SESSION_SECRET'],
///   sessionStore: RedisSessionStore(redis),
///   secureCookies: true, // HTTPS only
///   requestTimeout: Duration(seconds: 30),
/// );
/// ```
///
/// ## Features
///
/// - **Routing**: Express-style route handlers for GET, POST, PUT, DELETE, etc.
/// - **Middleware**: Composable request processing pipeline
/// - **Sessions**: Pluggable session stores with HMAC-SHA256 signing
/// - **Security**: Secure cookies, CORS, rate limiting built-in
/// - **DI**: Integration with get_it for dependency injection
/// - **Controllers**: Group related routes using controller pattern
///
/// See also:
/// - [Request] for accessing request data
/// - [Response] for sending responses
/// - [SessionStore] for custom session backends
class Fletch extends BaseContainer {
  /// Maximum size in bytes for request bodies (default: 10MB).
  final int maxBodySize;

  /// Maximum size in bytes for file uploads (default: 100MB).
  final int maxFileSize;

  /// Maximum time a request handler can run before timing out.
  ///
  /// Set to `null` to disable request timeouts entirely, which eliminates the
  /// per-request `Timer` allocation and is recommended for maximum throughput
  /// in environments that have their own timeout enforcement (load balancers,
  /// reverse proxies, etc.).
  ///
  /// Default: 30 seconds.
  final Duration? requestTimeout;

  /// Maximum time to wait for active requests during shutdown (default: 30s).
  final Duration shutdownTimeout;

  /// Secret key for HMAC-SHA256 session cookie signing.
  ///
  /// Must be at least 32 characters. Generate with:
  /// ```bash
  /// openssl rand -base64 48
  /// ```
  final String? sessionSecret;

  final List<MemoryRateLimitStore> _rateLimitStores = [];
  int _activeRequests = 0;
  bool _isShuttingDown = false;
  final DateTime _startTime = DateTime.now();

  /// Creates a new Fletch application instance.
  ///
  /// ## Parameters
  ///
  /// - [sessionSecret]: 32+ character secret for signing session cookies.
  ///   Required for production. Generate with `openssl rand -base64 48`.
  ///
  /// - [sessionStore]: External session storage backend (Redis, PostgreSQL, etc.).
  ///   Defaults to in-memory store (not suitable for multi-instance deployments).
  ///
  /// - [secureCookies]: Enable HTTPS-only cookies (default: true).
  ///   Set to `false` for local HTTP development.
  ///
  /// - [maxBodySize]: Maximum request body size (default: 10MB).
  ///
  /// - [maxFileSize]: Maximum file upload size (default: 100MB).
  ///
  /// - [requestTimeout]: Handler execution timeout (default: 30s).
  ///   Set to `null` to disable entirely — eliminates the per-request `Timer`
  ///   allocation and is recommended behind load balancers that enforce their
  ///   own upstream timeout.
  ///
  /// - [shutdownTimeout]: Graceful shutdown wait time (default: 30s).
  ///
  /// - [debug]: When `true`, full exception details are included in error
  ///   responses. Useful during development. **Never enable in production** —
  ///   exception strings can expose connection strings, file paths, and other
  ///   sensitive internal details. Default: `false`.
  ///
  /// - [useCookieParser]: Deprecated — cookies are now parsed lazily on first
  ///   access of `req.cookies`. This parameter has no effect.
  ///
  /// - [logger]: Custom logger instance. Defaults to console logger.
  ///
  /// - [router]: Custom router implementation. Defaults to RadixRouter.
  ///
  /// - [container]: Dependency injection container. Defaults to GetIt.instance.
  ///
  /// ## Example: Development
  ///
  /// ```dart
  /// final app = Fletch(
  ///   secureCookies: false, // Allow HTTP
  ///   sessionSecret: 'dev-secret-min-32-chars-long',
  /// );
  /// ```
  ///
  /// ## Example: Production
  ///
  /// ```dart
  /// final app = Fletch(
  ///   sessionSecret: Platform.environment['SESSION_SECRET']!,
  ///   sessionStore: RedisSessionStore(redis),
  ///   secureCookies: true, // HTTPS only
  ///   requestTimeout: Duration(seconds: 30),
  ///   maxBodySize: 5 * 1024 * 1024, // 5MB
  /// );
  /// ```
  ///
  /// ## Security Notes
  ///
  /// - Always use HTTPS in production (`secureCookies: true`)
  /// - Store [sessionSecret] in environment variables, never hardcode
  /// - Use external [sessionStore] for multi-instance deployments
  /// - Session cookies use httpOnly, SameSite=Lax by default
  Fletch({
    @Deprecated(
        'Cookie parsing is now lazy on req.cookies — this parameter has no effect and will be removed in a future release.')
    // ignore: deprecated_member_use_from_same_package
    bool useCookieParser = true,
    this.maxBodySize = 10 * 1024 * 1024, // 10MB
    this.maxFileSize = 100 * 1024 * 1024, // 100MB
    this.requestTimeout = const Duration(seconds: 30), // null = no timeout
    this.shutdownTimeout = const Duration(seconds: 30),
    super.debug = false,
    this.sessionSecret,
    SessionStore? sessionStore,
    super.secureCookies,
    super.logger,
    super.router,
    super.container,
  }) : super(
          sessionStore: sessionStore ?? MemorySessionStore(),
          sessionSigner:
              sessionSecret != null ? SessionSigner(sessionSecret) : null,
        ) {
    _validateConfig();
    // Cookie parsing is now demand-driven via req.cookies — no middleware needed.
  }

  /// Registers a [factory] that re-registers all routes and also exposes
  /// the `ext.fletch.reassemble` VM service extension so the dev tools can
  /// trigger a route reassembly after each hot reload.
  ///
  /// ```dart
  /// void main() async {
  ///   final app = Fletch();
  ///   app.hotReload(() => registerRoutes(app));
  ///   registerRoutes(app);
  ///   await app.listen(3000);
  /// }
  /// ```
  @override
  void hotReload(void Function() factory) {
    super.hotReload(factory);
    developer.registerExtension('ext.fletch.reassemble',
        (method, params) async {
      reassemble();
      return developer.ServiceExtensionResponse.result(
          '{"type":"@Event","kind":"Reassembled"}');
    });
  }

  /// Mounts an [IsolatedContainer] at the specified [prefix] path.
  ///
  /// This is a convenience method that mounts an isolated container to the
  /// main application at the specified prefix.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final authModule = IsolatedContainer();
  /// authModule.get('/login', loginHandler);
  /// authModule.post('/register', registerHandler);
  ///
  /// app.mount('/auth', authModule);
  /// ```
  ///
  /// The container will be automatically configured with the correct prefix.
  void mount(String prefix, IsolatedContainer container) {
    container.withPrefix(prefix).mount(this);
  }

  /// Registers a GET route handler at [path].
  ///
  /// Optional [middleware] runs after global middleware but before the handler.
  ///
  /// ## Example
  ///
  /// ```dart
  /// app.get('/users/:id', (req, res) {
  ///   final id = req.params['id'];
  ///   res.json({'userId': id});
  /// });
  ///
  /// // With middleware
  /// app.get('/admin', adminHandler, middleware: [authMiddleware]);
  /// ```
// HTTP method handlers (get, post, put, patch, delete, head, options)
// are inherited from BaseContainer

  final Map<HttpServer, Future<void>> _serverLifecycles = {};

  @override
  Future<void> handleRequest(HttpRequest httpRequest) {
    final request = Request.from(
      httpRequest,
      container: container,
      maxBodySize: maxBodySize,
      maxFileSize: maxFileSize,
      sessionSigner: sessionSigner,
      sessionStore: sessionStore,
    );
    final response = Response();
    // requestTimeout bounds dispatch (routing/middleware/handler) only, not
    // the response flush — see BaseContainer.processRequest's doc comment.
    // Passing null (the "disable timeout" configuration) skips the
    // .timeout() wrapper entirely, so no Timer is allocated either way.
    return processRequest(request, response, dispatchTimeout: requestTimeout);
  }

  /// Binds an [HttpServer] on the provided [port] (and optional [address]) and
  /// starts processing incoming requests in the background. The returned server
  /// can be closed by the caller when shutdown is required or during tests.
  Future<HttpServer> listen(
    int port, {
    InternetAddress? address,
    bool shared = false,
    int backlog = 0,
    bool v6Only = false,
  }) async {
    address ??= InternetAddress.anyIPv4;
    final server = await HttpServer.bind(
      address, port,
      shared: shared,
      backlog: backlog,
      v6Only: v6Only,
    );
    logger.i('Server listening on port ${server.port}');
    return _attachServer(server);
  }

  /// Binds an [HttpServer] over TLS on [port] using [context].
  ///
  /// ```dart
  /// final ctx = SecurityContext()
  ///   ..useCertificateChain('cert.pem')
  ///   ..usePrivateKey('key.pem');
  /// await app.listenSecure(443, ctx);
  /// ```
  Future<HttpServer> listenSecure(
    int port,
    SecurityContext context, {
    InternetAddress? address,
    bool shared = false,
    int backlog = 0,
    bool v6Only = false,
    bool requestClientCertificate = false,
  }) async {
    address ??= InternetAddress.anyIPv4;
    final server = await HttpServer.bindSecure(
      address, port, context,
      shared: shared,
      backlog: backlog,
      v6Only: v6Only,
      requestClientCertificate: requestClientCertificate,
    );
    logger.i('Server listening securely on port ${server.port}');
    return _attachServer(server);
  }

  /// Attaches Fletch to a pre-configured [server] and starts processing requests.
  ///
  /// Use this for full control — Unix sockets, custom TLS, or tests that
  /// create and tear down a server externally.
  ///
  /// ```dart
  /// final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
  /// await app.serveWith(server);
  /// ```
  Future<HttpServer> serveWith(HttpServer server) {
    logger.i('Serving on pre-configured server at port ${server.port}');
    return _attachServer(server);
  }

  Future<HttpServer> _attachServer(HttpServer server) {
    final lifecycle = _serve(server);
    _serverLifecycles[server] = lifecycle;
    lifecycle.whenComplete(() => _serverLifecycles.remove(server));
    return Future.value(server);
  }

  /// Awaits the internal request-processing loop for [server], ensuring any
  /// teardown logic has completed once the server has been closed. Useful for
  /// integration tests where the server is created and disposed per test case.
  Future<void> waitUntilClosed(HttpServer server) async {
    final lifecycle = _serverLifecycles[server];
    if (lifecycle != null) {
      await lifecycle;
    }
  }

  /// Creates a CORS middleware with configurable allow-lists.
  ///
  /// Handles preflight OPTIONS requests and sets appropriate CORS headers.
  ///
  /// ## Parameters
  ///
  /// - [allowedOrigins]: List of allowed origins. Use `['*']` for any origin
  ///   (not recommended in production). Defaults to `['*']`.
  ///
  /// - [allowedMethods]: HTTP methods to allow. Defaults to all methods.
  ///
  /// - [allowedHeaders]: Request headers to allow.
  ///   Defaults to `['Content-Type', 'Authorization']`.
  ///
  /// - [allowCredentials]: Allow credentials (cookies, auth headers).
  ///   Cannot be used with wildcard origins. Defaults to `false`.
  ///
  /// - [maxAge]: Preflight cache duration in seconds. Defaults to 86400 (24h).
  ///
  /// ## Example: Development
  ///
  /// ```dart
  /// // Allow all origins (dev only!)
  /// app.use(app.cors());
  /// ```
  ///
  /// ## Example: Production
  ///
  /// ```dart
  /// app.use(app.cors(
  ///   allowedOrigins: ['https://yourdomain.com', 'https://app.yourdomain.com'],
  ///   allowedMethods: ['GET', 'POST', 'PUT', 'DELETE'],
  ///   allowCredentials: true,
  /// ));
  /// ```
  ///
  /// ## Security Note
  ///
  /// Never use `allowedOrigins: ['*']` with `allowCredentials: true` as this
  /// creates a security vulnerability. This combination will throw an error.
  MiddlewareHandler cors({
    List<String> allowedOrigins = const ['*'],
    List<String> allowedMethods = RequestTypes.allTypes,
    List<String> allowedHeaders = const ['Content-Type', 'Authorization'],
    bool allowCredentials = false,
    int maxAge = 86400,
  }) {
    if (allowCredentials && allowedOrigins.contains('*')) {
      throw ArgumentError(
          'allowCredentials cannot be used with wildcard origins (*)');
    }

    return (request, response, next) async {
      final origin = request.headers.value('Origin');
      final method = request.method;

      // Check if the origin is allowed
      bool isAllowedOrigin(String? origin) {
        return origin != null &&
            (allowedOrigins.contains('*') || allowedOrigins.contains(origin));
      }

      final shouldEchoOrigin =
          allowedOrigins.isNotEmpty && !allowedOrigins.contains('*');

      if (shouldEchoOrigin && origin != null) {
        response.setHeader('Vary', 'Origin');
      }

      if (isAllowedOrigin(origin)) {
        // Set CORS headers
        final allowOriginHeader =
            allowedOrigins.contains('*') && !allowCredentials ? '*' : origin!;
        response.setHeader('Access-Control-Allow-Origin', allowOriginHeader);
        response.setHeader(
            'Access-Control-Allow-Methods', allowedMethods.join(', '));
        response.setHeader(
            'Access-Control-Allow-Headers', allowedHeaders.join(', '));
        response.setHeader('Access-Control-Max-Age', maxAge.toString());

        if (allowCredentials) {
          response.setHeader('Access-Control-Allow-Credentials', 'true');
        }

        // Handle preflight OPTIONS request
        if (method == 'OPTIONS') {
          response.setHeader(
              'Vary',
              response.headers['Vary'] == null
                  ? 'Origin'
                  : response.headers['Vary']!);
          response.setHeader(
              'Access-Control-Allow-Headers',
              request.headers.value('access-control-request-headers') ??
                  allowedHeaders.join(', '));
          response.setStatus(HttpStatus.noContent); // 204 No Content
          await response.send(request.httpRequest.response);
          return;
        }
      } else if (origin != null && !isAllowedOrigin(origin)) {
        // If origin is not allowed, log and respond with 403 Forbidden
        logger.w('CORS denied - origin not allowed: $origin');
        response.setStatus(HttpStatus.forbidden);
        response.text('CORS policy does not allow this origin.');
        await response.send(request.httpRequest.response);
        return;
      } else if (!allowedMethods.contains(method)) {
        // If method is not allowed, respond with 405 Method Not Allowed
        logger.w('CORS denied - method not allowed: $method');
        response.setStatus(HttpStatus.methodNotAllowed);
        response.text('Method not allowed.');
        await response.send(request.httpRequest.response);
        return;
      }

      // Set additional security headers
      response.setHeader(
          'Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
      response.setHeader('X-Content-Type-Options', 'nosniff');
      response.setHeader('X-Frame-Options', 'DENY');

      await next();
    };
  }

  /// Builds a rate limiter middleware backed by [store] (or an in-memory
  /// default). Requests exceeding [maxRequests] within [window] receive a 429
  /// response. Customize [keyGenerator] to throttle by user/token/etc.
  ///
  /// ## Reverse-proxy deployments
  ///
  /// The default key is the **TCP-layer remote IP**. Behind a reverse proxy
  /// (nginx, Cloudflare, AWS ALB) every request arrives from the proxy's IP,
  /// collapsing all real clients into a single bucket.
  ///
  /// Supply a [keyGenerator] that reads a trusted forwarded-IP header instead:
  ///
  /// ```dart
  /// app.use(app.rateLimiter(
  ///   keyGenerator: (req) {
  ///     // Only read this header when you control the proxy and it strips
  ///     // any client-supplied X-Forwarded-For before adding its own.
  ///     final forwarded = req.headers.value('x-forwarded-for');
  ///     // Take the first IP in the chain (original client).
  ///     return forwarded?.split(',').first.trim()
  ///         ?? req.httpRequest.connectionInfo?.remoteAddress.address
  ///         ?? 'unknown';
  ///   },
  /// ));
  /// ```
  ///
  /// **Warning**: never trust `X-Forwarded-For` unless your proxy is
  /// configured to strip the header from incoming client requests first.
  MiddlewareHandler rateLimiter({
    int maxRequests = 100,
    Duration window = const Duration(minutes: 1),
    String Function(Request request)? keyGenerator,
    RateLimitStore? store,
  }) {
    final effectiveStore = store ?? MemoryRateLimitStore();

    // Track memory stores for cleanup
    if (effectiveStore is MemoryRateLimitStore && store == null) {
      _rateLimitStores.add(effectiveStore);
    }

    return (request, response, next) async {
      final key = keyGenerator != null
          ? keyGenerator(request)
          : request.httpRequest.connectionInfo?.remoteAddress.address ??
              'unknown';

      final isAllowed =
          await effectiveStore.increment(key, maxRequests, window);

      if (!isAllowed) {
        response.setStatus(HttpStatus.tooManyRequests);
        response.text('Rate limit exceeded. Try again later.');
        return;
      }

      await next();
    };
  }

  /// Enable a simple health check endpoint at /health
  void enableHealthCheck() {
    get('/health', (req, res) {
      res.json({
        'status': 'ok',
        'uptime': DateTime.now().difference(_startTime).inSeconds,
        'activeRequests': _activeRequests,
      });
    });
  }

  /// Gracefully closes all servers, waiting for active requests to complete
  Future<void> close() async {
    _isShuttingDown = true;

    logger.i(
        'Graceful shutdown initiated. Waiting for $_activeRequests active requests...');

    final deadline = DateTime.now().add(shutdownTimeout);
    while (_activeRequests > 0 && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (_activeRequests > 0) {
      logger.w(
          'Forcefully closing with $_activeRequests active requests still in-flight');
    } else {
      logger.i('All requests completed. Closing servers.');
    }

    // Allow a short grace window for late-arriving requests to receive 503s
    await Future.delayed(const Duration(milliseconds: 50));

    for (final server in _serverLifecycles.keys.toList()) {
      final lifecycle = _serverLifecycles[server];
      await server.close(force: _activeRequests > 0);
      if (lifecycle != null) {
        await lifecycle;
      }
    }

    _serverLifecycles.clear();
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final httpRequest in server) {
        // Fire and forget - no blocking, trust Dart's event loop
        unawaited(_handleRequestWithTimeout(httpRequest));
      }
    } finally {
      // Clean up rate limiter stores
      for (final store in _rateLimitStores) {
        try {
          store.dispose();
        } catch (e, stack) {
          logger.e('Error disposing rate limiter store',
              error: e, stackTrace: stack);
        }
      }

      // Clean up session store resources
      if (sessionStore != null) {
        try {
          await sessionStore!.dispose();
        } catch (e, stack) {
          logger.e('Error disposing session store',
              error: e, stackTrace: stack);
        }
      }
      await onDispose();
    }
  }

  Future<void> _handleRequestWithTimeout(HttpRequest httpRequest) {
    // Reject new requests during shutdown
    if (_isShuttingDown) {
      httpRequest.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.add('Connection', 'close')
        ..write('Server is shutting down')
        ..close();
      return Future.value();
    }

    _activeRequests++;

    // requestTimeout is now enforced inside processRequest, scoped to
    // dispatch only, so it doesn't cut off an already-awaited streaming
    // response (see handleRequest above). This catchError remains as a
    // last-resort safety net for anything that escapes processRequest's
    // own error handling entirely.
    // Avoid async/await here so no extra Future wrapper is allocated on the
    // hot path — handleRequest()'s own Future is chained directly.
    return handleRequest(httpRequest)
        .catchError((Object error, StackTrace stackTrace) =>
            _safelySendErrorResponse(httpRequest, error, stackTrace))
        .whenComplete(() => _activeRequests--);
  }

  Future<void> _safelySendErrorResponse(
    HttpRequest httpRequest,
    dynamic error,
    StackTrace stackTrace,
  ) async {
    logger.e(
        'Request error ${httpRequest.method} ${httpRequest.uri.path} '
        'reqId=${httpRequest.headers.value('x-request-id') ?? '-'}',
        error: error,
        stackTrace: stackTrace,
        time: DateTime.now());
    try {
      final statusCode = error is HttpError ? error.statusCode : 500;

      final errorMessage = error is HttpError
          ? error.message
          : debug
              ? error.toString()
              : 'Internal Server Error';
      httpRequest.response
        ..statusCode = statusCode
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': errorMessage,
          'statusCode': statusCode,
        }));

      await httpRequest.response.close();
    } catch (_) {
      // If we can't send error response, just try to close
      try {
        await httpRequest.response.close();
      } catch (_) {
        // Nothing more we can do
      }
    }
  }

  void _validateConfig() {
    if (maxBodySize <= 0) {
      throw ArgumentError('maxBodySize must be positive');
    }
    if (maxFileSize <= 0) {
      throw ArgumentError('maxFileSize must be positive');
    }
    if (requestTimeout != null && requestTimeout! <= Duration.zero) {
      throw ArgumentError('requestTimeout must be positive (or null to disable)');
    }
    if (shutdownTimeout <= Duration.zero) {
      throw ArgumentError('shutdownTimeout must be positive');
    }
    if (maxFileSize > maxBodySize) {
      logger.w(
          'maxFileSize ($maxFileSize) is greater than maxBodySize ($maxBodySize); large uploads may hit body limit first.');
    }

    if (sessionSecret != null) {
      logger.i('✅ Session security enabled with HMAC-SHA256 signing');
    } else {
      logger.w('⚠️  No session secret configured - sessions will be unsigned!');
    }

    if (secureCookies) {
      logger.i('✅ Secure cookies enabled (HTTPS required)');
      logger.i('   💡 For local HTTP development, set secureCookies: false');
    } else {
      logger.w('⚠️  Secure cookies DISABLED - only use in development!');
      logger.w('   HTTPS is REQUIRED for production deployments');
    }
  }
}
