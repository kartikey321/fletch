import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:fletch/src/middleware/cookies_parser.dart';

/// Common HTTP method constants used across the framework.
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

  /// Maximum time a request handler can run before timeout (default: 30s).
  final Duration requestTimeout;

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
  ///
  /// - [shutdownTimeout]: Graceful shutdown wait time (default: 30s).
  ///
  /// - [useCookieParser]: Auto-parse Cookie header (default: true).
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
    bool useCookieParser = true,
    this.maxBodySize = 10 * 1024 * 1024, // 10MB
    this.maxFileSize = 100 * 1024 * 1024, // 100MB
    this.requestTimeout = const Duration(seconds: 30),
    this.shutdownTimeout = const Duration(seconds: 30),
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
    if (useCookieParser) {
      use(CookieParser.middleware());
    }
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
  Future<void> handleRequest(HttpRequest httpRequest) async {
    final request = Request.from(
      httpRequest,
      container: container,
      maxBodySize: maxBodySize,
      maxFileSize: maxFileSize,
      sessionSigner: sessionSigner,
      sessionStore: sessionStore,
    );
    final response = Response();
    await processRequest(request, response);
  }

  /// Binds an [HttpServer] on the provided [port] (and optional [address]) and
  /// starts processing incoming requests in the background. The returned server
  /// can be closed by the caller when shutdown is required or during tests.
  Future<HttpServer> listen(
    int port, {
    InternetAddress? address,
    bool shared = false,
  }) async {
    address ??= InternetAddress.anyIPv4;
    final server = await HttpServer.bind(address, port, shared: shared);
    logger.i('Server listening on port ${server.port}');

    final lifecycle = _serve(server);
    _serverLifecycles[server] = lifecycle;
    lifecycle.whenComplete(() => _serverLifecycles.remove(server));

    return server;
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
          response.send(request.httpRequest.response);
          return;
        }
      } else if (origin != null && !isAllowedOrigin(origin)) {
        // If origin is not allowed, log and respond with 403 Forbidden
        logger.w('CORS denied - origin not allowed: $origin');
        response.setStatus(HttpStatus.forbidden);
        response.text('CORS policy does not allow this origin.');
        response.send(request.httpRequest.response);
        return;
      } else if (!allowedMethods.contains(method)) {
        // If method is not allowed, respond with 405 Method Not Allowed
        logger.w('CORS denied - method not allowed: $method');
        response.setStatus(HttpStatus.methodNotAllowed);
        response.text('Method not allowed.');
        response.send(request.httpRequest.response);
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

  Future<void> _handleRequestWithTimeout(HttpRequest httpRequest) async {
    // Reject new requests during shutdown
    if (_isShuttingDown) {
      httpRequest.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.add('Connection', 'close')
        ..write('Server is shutting down')
        ..close();
      return;
    }

    _activeRequests++;

    try {
      await handleRequest(httpRequest).timeout(
        requestTimeout,
        onTimeout: () => throw HttpError(408, 'Request Timeout'),
      );
    } catch (error, stackTrace) {
      await _safelySendErrorResponse(httpRequest, error, stackTrace);
    } finally {
      _activeRequests--;
    }
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

      httpRequest.response
        ..statusCode = statusCode
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': error.toString(),
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
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError('requestTimeout must be positive');
    }
    if (shutdownTimeout <= Duration.zero) {
      throw ArgumentError('shutdownTimeout must be positive');
    }
    if (maxFileSize > maxBodySize) {
      logger.w(
          'maxFileSize ($maxFileSize) is greater than maxBodySize ($maxBodySize); large uploads may hit body limit first.');
    }

    if (sessionSecret != null && sessionSecret!.length < 32) {
      throw StateError(
          'sessionSecret must be at least 32 characters for security');
    }

    if (sessionSecret != null) {
      logger.i('✅ Session security enabled with HMAC-SHA256 signing');
    } else {
      logger.w('⚠️  No session secret configured - sessions will be unsigned!');
    }

    if (sessionStore == null) {
      logger.w(
          '⚠️  Using in-memory session store - sessions will be lost on restart');
      logger.w(
          '   For production, configure an external store (Redis, PostgreSQL, etc.)');
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
