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

  /// Removes all globally registered middleware.
  ///
  /// Intended for dev-reload tooling that rebuilds route/middleware
  /// registration from scratch: pairs with [RouterInterface.clear] so a
  /// reassembled app doesn't accumulate duplicate global middleware on
  /// every reload cycle.
  void clearMiddleware() {
    _middleware.clear();
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

  /// Clears all registered routes and global middleware, then re-registers
  /// them via the factory set by [hotReload]. Called by the VM service
  /// extension after a successful hot reload so updated named handler
  /// bodies take effect.
  ///
  /// Middleware is cleared too (not just routes) so a factory that calls
  /// `app.use(...)` doesn't accumulate duplicate global middleware on every
  /// reload cycle.
  void reassemble() {
    if (_routeFactory == null) return;
    router.clear();
    clearMiddleware();
    _routeFactory!();
  }

  /// Installs a global error handler.
  void setErrorHandler(ErrorHandler handler) {
    _errorHandler = handler;
  }

  /// Wraps [handler] with [routeMiddleware] only. Global middleware is no
  /// longer applied here — it wraps route resolution and the handler from
  /// [processRequest] instead (see that method's doc comment for exactly
  /// what it does and does not observe), so it can see unmatched routes
  /// (404s), not just a successfully matched handler.
  @protected
  RequestHandler wrapWithMiddleware(
      RequestHandler handler, List<MiddlewareHandler> routeMiddleware) {
    // Fast path: no route-level middleware — return the handler directly,
    // zero-overhead, non-async.
    if (routeMiddleware.isEmpty) {
      return handler;
    }

    // Route has its own middleware — full chain, still non-async.
    return (Request request, Response response) {
      int routeIndex = 0;
      FutureOr<void> runNext() {
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
  ///
  /// Global middleware wraps route resolution, route middleware, and the
  /// handler, so `next()` now observes unmatched routes (404s) and
  /// exceptions thrown while the handler *sets up* its response — not just
  /// a successfully matched handler returning normally.
  ///
  /// It does **not** wrap [Response.send] — the actual flush (headers +
  /// body, and for SSE/streaming responses, the handler body that only runs
  /// during `send()`) happens after `await next()` has already returned to
  /// the outermost middleware. Middleware cannot observe streaming
  /// completion or errors thrown from inside an SSE handler body; those are
  /// caught here and logged instead (see the `else` branch below). Fixing
  /// that fully would require nesting the flush *inside* the awaited
  /// dispatch chain, which would also pull it inside [dispatchTimeout] and
  /// reintroduce the stream-truncation problem this scoping exists to avoid
  /// — a real tradeoff, not addressed by this change.
  ///
  /// The session store write only runs after the flush attempt (in
  /// `finally`), since streaming/SSE handler bodies only actually execute
  /// inside [Response.send], not when the route handler returns.
  ///
  /// [dispatchTimeout], if provided, bounds only route resolution + route
  /// middleware + the handler — deliberately *not* the response flush.
  /// Streaming/SSE handlers only configure themselves during dispatch (fast)
  /// and do their actual work inside `send()`; scoping the timeout this way
  /// preserves long-lived streams instead of cutting them off once
  /// `response.send()` is properly awaited (see [Fletch.handleRequest]).
  ///
  /// Known limitation: `Future.timeout()` cannot cancel the original
  /// dispatch future. If it fires, the abandoned dispatch keeps running in
  /// the background and may still mutate `request`/`response` state after
  /// the 408 has already been sent and (if the session was already touched)
  /// after the `finally` block below has already run `session.save()` —
  /// that later mutation has no corresponding save and is silently lost.
  /// This is a general Dart limitation, not something scoping the timeout
  /// here can fix.
  @protected
  Future<void> processRequest(
    Request request,
    Response response, {
    Duration? dispatchTimeout,
  }) async {
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
      final dispatch = _dispatchThroughGlobalMiddleware(request, response);
      if (dispatchTimeout != null) {
        await dispatch.timeout(
          dispatchTimeout,
          onTimeout: () => throw HttpError(408, 'Request Timeout'),
        );
      } else {
        await dispatch;
      }
      if (!response.isSent) {
        _applySessionCookie(request, response);
        await response.send(request.httpRequest.response);
      }
    } catch (error, stackTrace) {
      if (!response.isSent) {
        await handleError(error, request, response, stackTrace);
        if (!response.isSent) {
          _applySessionCookie(request, response);
          await response.send(request.httpRequest.response);
        }
      } else {
        // Response already started flushing (e.g. a streaming/SSE handler
        // threw after writing began) — headers/status are already on the
        // wire, so there's nothing left to send. Surface the failure
        // instead of letting it escape uncaught.
        logger.e('Error after response flush began for ${request.method} '
            '${request.uri.path}',
            error: error, stackTrace: stackTrace);
      }
    } finally {
      // Only perform the session store write if the handler (or its
      // middleware) actually touched req.session — skips store I/O on
      // routes that never need a session (e.g. health checks). Runs after
      // the flush attempt so mutations made inside a streaming/SSE handler
      // body (which only runs during `send`) are captured.
      if (request.sessionTouched) {
        final session = request.session;
        // `sessionTouched` fires on any `request.session` access, including
        // incidental reads that don't mutate anything (e.g. IsolatedContainer's
        // routing delegate reads `.session.id` for every mounted request
        // regardless of whether the handler uses sessions at all). Only a
        // session with real, unsaved changes is actually at risk of being
        // silently lost or unreachably persisted below.
        if (session.isDirty &&
            (request.isNewSession || session.wasRegenerated) &&
            !response.hasCookie(Request.sessionCookieName)) {
          // Session data was set (or the session was regenerated) *after*
          // headers were already flushed — e.g. inside an SSE/stream handler
          // body, which only runs during `send()`, by which point
          // _applySessionCookie's pre-send check already ran and saw an
          // untouched session. There is no way to get a Set-Cookie onto a
          // response whose headers are already on the wire, so the client
          // can never present this session ID again. Persisting it anyway
          // would just leak an unreachable row into the session store.
          logger.w(
              'Session data set after response headers were already sent for '
              '${request.method} ${request.uri.path} (e.g. inside an SSE or '
              'streaming handler body on a brand-new/regenerated session) — '
              'no Set-Cookie could be issued, so this session is discarded '
              'instead of being persisted unreachably.');
        } else {
          try {
            // No-ops internally if the session was touched but never
            // actually marked dirty (isDirty guard inside Session.save()).
            await session.save();
          } catch (e, stack) {
            logger.e('Failed to save session', error: e, stackTrace: stack);
          }
        }
      }
    }
  }

  /// Sets the session cookie when needed: a brand-new session, or one that
  /// was regenerated (new ID after privilege escalation, e.g. login). Must
  /// run before [Response.send] — cookies can't be added once headers are
  /// flushed — so this is called right before each `send()` call site
  /// rather than deferred to the post-flush session-save step.
  void _applySessionCookie(Request request, Response response) {
    if (!request.sessionTouched) return;
    final session = request.session;
    final needsCookie = (request.isNewSession || session.wasRegenerated) &&
        !response.hasCookie(Request.sessionCookieName);
    if (!needsCookie) return;

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

  /// Runs global middleware around route resolution + the matched handler
  /// (or throws [NotFoundError] for an unmatched route), so global
  /// middleware can observe both outcomes. Resolves once the handler
  /// function *returns* — for SSE/streaming routes that's before the
  /// actual streamed work runs (see [processRequest]'s doc comment).
  Future<void> _dispatchThroughGlobalMiddleware(
      Request request, Response response) {
    if (_middleware.isEmpty) {
      return _resolveAndDispatch(request, response);
    }
    int globalIndex = 0;
    Future<void> runNextMiddleware() async {
      if (globalIndex < _middleware.length) {
        await _middleware[globalIndex++](request, response, runNextMiddleware);
        return;
      }
      await _resolveAndDispatch(request, response);
    }

    return runNextMiddleware();
  }

  Future<void> _resolveAndDispatch(Request request, Response response) async {
    final resolvedPath = resolveRoutePath(request);
    final routeMatch = router.findRoute(request.method, resolvedPath);
    request.params = routeMatch?.pathParams ?? {};
    if (routeMatch != null) {
      await routeMatch.handler(request, response);
    } else {
      throw NotFoundError('Route not found: $resolvedPath');
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
