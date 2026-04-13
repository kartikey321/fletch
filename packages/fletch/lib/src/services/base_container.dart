import 'dart:async';
import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:get_it/get_it.dart';
import 'package:meta/meta.dart';
import 'package:logger/logger.dart';

import '../router/router_interface.dart';

/// Core runtime wiring shared by [Fletch] and other container variants.
/// Provides middleware composition, dependency registration helpers, and
/// request lifecycle utilities.
abstract class BaseContainer {
  final RouterInterface router;
  final List<MiddlewareHandler> _middleware = [];
  final GetIt container;
  final bool secureCookies;

  /// When `true`, full exception details (stack traces, internal messages) are
  /// included in error responses.  Keep `false` (the default) in production
  /// to avoid leaking internal implementation details to clients.
  final bool debug;

  final SessionStore? sessionStore;
  final SessionSigner? sessionSigner;
  ErrorHandler? _errorHandler;
  late final Logger logger;
  void Function()? _routeFactory;

  /// Creates a container with optional overrides for router and dependency
  /// scope.
  BaseContainer({
    RouterInterface? router,
    GetIt? container,
    Logger? logger,
    this.secureCookies = true,
    this.debug = false,
    this.sessionStore,
    this.sessionSigner,
  })  : router = router ?? RadixRouter(),
        container = container ?? GetIt.instance {
    this.logger = logger ?? _defaultLogger();
  }

  /// Adds a global [middleware] to the container.
  void use(MiddlewareHandler middleware) {
    _middleware.add(middleware);
  }

  /// Mounts a [Controller] at the specified [prefix] path.
  ///
  /// All routes registered in the controller will be prefixed with [prefix].
  ///
  /// ## Example
  ///
  /// ```dart
  /// class UserController extends Controller {
  ///   @override
  ///   void registerRoutes(ControllerOptions options) {
  ///     options.get('/list', listUsers); // -> GET /users/list
  ///     options.post('/create', createUser); // -> POST /users/create
  ///   }
  /// }
  ///
  /// app.useController('/users', UserController());
  /// ```
  void useController(String prefix, Controller controller) {
    controller.initialize(this, prefix: prefix);
  }

  /// Resolves a registered service of type [T] from the DI container.
  ///
  /// Use this when constructing controllers or passing services to factories
  /// at startup, after all registrations are done:
  ///
  /// ```dart
  /// app.registerSingleton<UserService>(UserService(db));
  /// app.useController('/users', UserController(app.resolve<UserService>()));
  /// ```
  T resolve<T extends Object>({String? instanceName}) =>
      container.get<T>(instanceName: instanceName);

  /// Registers a pre-built [instance] that will be served for type [T].
  void inject<T extends Object>(T instance) {
    container.registerSingleton<T>(instance);
  }

  /// Registers an eagerly created singleton for [T].
  void registerSingleton<T extends Object>(T instance) {
    container.registerSingleton<T>(instance);
  }

  /// Registers a factory invoked on each access to [T].
  void registerFactory<T extends Object>(T Function() factoryFunc) {
    container.registerFactory<T>(factoryFunc);
  }

  /// Registers a lazily created singleton for [T].
  void registerLazySingleton<T extends Object>(T Function() factoryFunc) {
    container.registerLazySingleton<T>(factoryFunc);
  }

  /// Registers an asynchronously produced singleton.
  void registerSingletonAsync<T extends Object>(
      Future<T> Function() asyncFactoryFunc) {
    container.registerSingletonAsync<T>(asyncFactoryFunc);
  }

  /// Registers an asynchronously produced factory provider.
  void registerFactoryAsync<T extends Object>(
      Future<T> Function() asyncFactoryFunc) {
    container.registerFactoryAsync<T>(asyncFactoryFunc);
  }

  /// Registers an asynchronously produced lazy singleton.
  void registerLazySingletonAsync<T extends Object>(
      Future<T> Function() asyncFactoryFunc) {
    container.registerLazySingletonAsync<T>(asyncFactoryFunc);
  }

  /// Checks whether [T] is already registered.
  bool isRegistered<T extends Object>({Object? instance}) {
    return container.isRegistered<T>(instance: instance);
  }

  /// Unregisters the existing binding for [T].
  void unregister<T extends Object>() {
    container.unregister<T>();
  }

  /// Registers a [factory] callback that re-registers all routes.
  ///
  /// Call this in your server's `main()` before `listen()` to enable
  /// Phoenix-style hot reload: after each successful VM source reload,
  /// the dev tools will invoke [reassemble] which clears the router and
  /// re-calls [factory] so updated named function references take effect.
  ///
  /// ```dart
  /// void main() async {
  ///   final app = Fletch();
  ///   app.hotReload(() => registerRoutes(app));
  ///   registerRoutes(app);
  ///   await app.listen(3000);
  /// }
  /// ```
  void hotReload(void Function() factory) {
    _routeFactory = factory;
  }

  /// Clears all registered routes and re-registers them via the factory
  /// set by [hotReload]. Called by the VM service extension after a
  /// successful hot reload so updated named handler bodies take effect.
  void reassemble() {
    if (_routeFactory == null) return;
    router.clear();
    _routeFactory!();
  }

  /// Installs a global error handler.
  void setErrorHandler(ErrorHandler handler) {
    _errorHandler = handler;
  }

  @protected
  RequestHandler wrapWithMiddleware(
      RequestHandler handler, List<MiddlewareHandler> routeMiddleware) {
    // Fast path: no route-level middleware. Check global middleware at call
    // time (it can be added after route registration via app.use()).
    if (routeMiddleware.isEmpty) {
      // Non-async: the handler's own Future is returned directly with no extra
      // wrapping. When _middleware is empty the whole call is zero-overhead.
      return (Request request, Response response) {
        if (_middleware.isEmpty) {
          return handler(request, response);
        }
        int index = 0;
        FutureOr<void> runNext() {
          if (index < _middleware.length) {
            return _middleware[index++](request, response, runNext);
          }
          return handler(request, response);
        }
        return runNext();
      };
    }

    // Route has its own middleware — full chain, still non-async.
    return (Request request, Response response) {
      int globalIndex = 0;
      int routeIndex = 0;
      FutureOr<void> runNext() {
        if (globalIndex < _middleware.length) {
          return _middleware[globalIndex++](request, response, runNext);
        }
        if (routeIndex < routeMiddleware.length) {
          return routeMiddleware[routeIndex++](request, response, runNext);
        }
        return handler(request, response);
      }
      return runNext();
    };
  }

  @protected
  void addRoute(String method, String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    final wrappedHandler = wrapWithMiddleware(handler, middleware ?? []);
    router.addRoute(method, path, wrappedHandler);
  }

  /// Registers a GET route handler at [path].
  void get(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.GET, path, handler, middleware: middleware);
  }

  /// Registers a POST route handler at [path].
  void post(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.POST, path, handler, middleware: middleware);
  }

  /// Registers a PUT route handler at [path].
  void put(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.PUT, path, handler, middleware: middleware);
  }

  /// Registers a PATCH route handler at [path].
  void patch(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.PATCH, path, handler, middleware: middleware);
  }

  /// Registers a DELETE route handler at [path].
  void delete(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.DELETE, path, handler, middleware: middleware);
  }

  /// Registers a HEAD route handler at [path].
  ///
  /// HEAD requests are identical to GET except the server must not return
  /// a message body in the response.
  void head(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.HEAD, path, handler, middleware: middleware);
  }

  /// Registers an OPTIONS route handler at [path].
  void options(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    addRoute(RequestTypes.OPTIONS, path, handler, middleware: middleware);
  }

  /// Orchestrates the full request lifecycle: building framework abstractions,
  /// resolving routes, executing middleware/handlers and finally flushing the
  /// response (including error handling and session propagation).
  @protected
  Future<void> handleRequest(HttpRequest httpRequest) {
    final request = Request.from(
      httpRequest,
      container: container,
      sessionSigner: sessionSigner,
      sessionStore: sessionStore,
    );
    return processRequest(request, Response());
  }

  /// Executes middleware + handler pipeline for a prepared [request] and
  /// [response]. If a route does not complete the response, it is sent here.
  @protected
  Future<void> processRequest(Request request, Response response) async {
    // Only eagerly load session for returning visitors — new sessions have no
    // stored data so the load is always a no-op and we can skip the I/O.
    if (!request.isNewSession) {
      try {
        await request.preloadSession(); // bypasses sessionTouched flag
      } catch (e, stack) {
        logger.e('Failed to load session', error: e, stackTrace: stack);
        // Continue with empty session rather than crashing request
      }
    }

    // Echo correlation ID only when the client sent one — free for benchmark
    // traffic that omits the header, still works for tracing in production.
    // We check the backing field directly (null iff no header was sent) rather
    // than re-reading HttpHeaders — eliminates 2 lookups on every request.
    if (request.hasIncomingRequestId) {
      response.setHeader('X-Request-Id', request.requestId);
    }

    try {
      final resolvedPath = resolveRoutePath(request);
      final routeMatch = router.findRoute(request.method, resolvedPath);
      request.params = routeMatch?.pathParams ?? {};
      if (routeMatch != null) {
        await routeMatch.handler(request, response);
      } else {
        throw NotFoundError('Route not found: $resolvedPath');
      }
    } catch (error, stackTrace) {
      await handleError(error, request, response, stackTrace);
    }

    // Only perform session persistence if the handler (or its middleware)
    // actually touched req.session — skips all cookie + store work on routes
    // that never need a session (e.g. health checks, public API endpoints).
    if (request.sessionTouched) {
      final session = request.session;

      // Emit Set-Cookie when: (a) brand-new session, or (b) session was
      // regenerated (new ID after privilege escalation, e.g. login).
      final needsCookie = (request.isNewSession || session.wasRegenerated) &&
          !response.hasCookie(Request.sessionCookieName);
      if (needsCookie) {
        String cookieValue = session.id;
        if (request.sessionSigner != null) {
          cookieValue = request.sessionSigner!.sign(session.id);
        }
        response.cookie(
          Request.sessionCookieName,
          cookieValue,
          secure: secureCookies,
          httpOnly: true,
          sameSite: SameSite.lax,
        );
      }

      // Save session data to store if modified
      try {
        await session.save();
      } catch (e, stack) {
        logger.e('Failed to save session', error: e, stackTrace: stack);
      }
    }

    if (!response.isSent) {
      response.send(request.httpRequest.response);
    }
  }

  /// Resolves the path used for route lookup. Subclasses can override to provide
  /// custom behaviour (e.g., stripping a mount prefix).
  @protected
  String resolveRoutePath(Request request) => request.uri.path;

  /// Default error handling entry point. Subclasses may override to plug in
  /// different behaviour.
  @protected
  Future<void> handleError(dynamic error, Request request, Response response,
      StackTrace stackTrace) async {
    if (_errorHandler != null) {
      try {
        await _errorHandler!(error, request, response);
        // Ensure error handler actually sent a response
        if (!response.isSent) {
          logger.w(
              'Error handler did not send response, using fallback for ${request.method} ${request.uri.path}');
          _sendDefaultError(error, response, stackTrace);
        }
      } catch (e, st) {
        logger.e(
            'Error in error handler for ${request.method} ${request.uri.path}',
            error: e,
            stackTrace: st);
        // Fall through to default error handling
        if (!response.isSent) {
          _sendDefaultError(error, response, stackTrace);
        }
      }
    } else {
      _sendDefaultError(error, response, stackTrace);
    }
  }

  void _sendDefaultError(
      dynamic error, Response response, StackTrace stackTrace) {
    if (response.isSent) return;

    logger.e('Unhandled error', error: error, stackTrace: stackTrace);
    if (error is HttpError) {
      response.setStatus(error.statusCode);
      response.json({'error': error.message, 'data': error.data});
    } else {
      response.setStatus(HttpStatus.internalServerError);
      final body = <String, dynamic>{'error': 'Internal Server Error'};
      // Only expose internal details in debug mode — in production, leaking
      // exception messages can reveal DB connection strings, file paths, etc.
      if (debug) body['message'] = error.toString();
      response.json(body);
    }
  }

  /// Disposes the dependency container and any subclass resources.
  Future<void> onDispose() async {
    // Dispose session store if provided
    await sessionStore?.dispose();
    await container.reset();
  }

  static Logger _defaultLogger() {
    return Logger(
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 5,
        lineLength: 120,
        printEmojis: false,
        dateTimeFormat: DateTimeFormat.none,
      ),
    );
  }
}
