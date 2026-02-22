import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:get_it/get_it.dart';
import 'package:meta/meta.dart';
import 'package:logger/logger.dart';

import '../router/router_interface.dart';
import 'controller.dart';

/// Core runtime wiring shared by [Fletch] and other container variants.
/// Provides middleware composition, dependency registration helpers, and
/// request lifecycle utilities.
abstract class BaseContainer {
  final RouterInterface router;
  final List<MiddlewareHandler> _middleware = [];
  final GetIt container;
  final bool secureCookies;
  final SessionStore? sessionStore;
  final SessionSigner? sessionSigner;
  ErrorHandler? _errorHandler;
  late final Logger logger;

  /// Creates a container with optional overrides for router and dependency
  /// scope.
  BaseContainer({
    RouterInterface? router,
    GetIt? container,
    Logger? logger,
    this.secureCookies = true,
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

  /// Installs a global error handler.
  void setErrorHandler(ErrorHandler handler) {
    _errorHandler = handler;
  }

  @protected
  RequestHandler wrapWithMiddleware(
      RequestHandler handler, List<MiddlewareHandler> routeMiddleware) {
    return (Request request, Response response) async {
      int globalIndex = 0;
      int routeIndex = 0;

      Future<void> runNextMiddleware() async {
        if (globalIndex < _middleware.length) {
          await _middleware[globalIndex++](
              request, response, runNextMiddleware);
        } else if (routeIndex < routeMiddleware.length) {
          await routeMiddleware[routeIndex++](
              request, response, runNextMiddleware);
        } else {
          await handler(request, response);
        }
      }

      await runNextMiddleware();
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
  Future<void> handleRequest(HttpRequest httpRequest) async {
    final request = Request.from(
      httpRequest,
      container: container,
      sessionSigner: sessionSigner,
      sessionStore: sessionStore,
    );
    final response = Response();
    await processRequest(request, response);
  }

  /// Executes middleware + handler pipeline for a prepared [request] and
  /// [response]. If a route does not complete the response, it is sent here.
  @protected
  Future<void> processRequest(Request request, Response response) async {
    // Load session data from store (with error handling)
    try {
      await request.session.load();
    } catch (e, stack) {
      logger.e('Failed to load session', error: e, stackTrace: stack);
      // Continue with empty session rather than crashing request
    }

    // Set up session cookie for new sessions
    if (request.isNewSession &&
        !response.hasCookie(Request.sessionCookieName)) {
      // Determine session cookie value (signed or plain)
      String cookieValue = request.session.id;
      if (request.sessionSigner != null) {
        cookieValue = request.sessionSigner!.sign(request.session.id);
      }

      // Set session cookie with configured security settings
      response.cookie(
        Request.sessionCookieName,
        cookieValue,
        secure: secureCookies,
        httpOnly: true,
        sameSite: SameSite.lax,
      );
    }

    // Attach request correlation id to response for tracing
    response.setHeader('X-Request-Id', request.requestId);

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

    // Save session data to store if modified (with error handling)
    try {
      await request.session.save();
    } catch (e, stack) {
      logger.e('Failed to save session', error: e, stackTrace: stack);
      // Log error but don't fail the request
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
      response.json(
          {'error': 'Internal Server Error', 'message': error.toString()});
    }
  }

  /// Disposes the dependency container and any subclass resources.
  Future<void> onDispose() async {
    // Dispose session store if provided
    await sessionStore?.dispose();
    container.reset();
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
