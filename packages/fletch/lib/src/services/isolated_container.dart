import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:get_it/get_it.dart';

import '../router/router_interface.dart';

/// A container that can be mounted under a specific prefix with its own router,
/// middleware pipeline and dependency injection scope.
///
/// When mounted it reuses the parent [`Response`] instance so that cookies,
/// headers, and streaming behaviour are coordinated with the hosting
/// application while requests are rebuilt against the isolated dependency
/// scope.
class IsolatedContainer extends BaseContainer {
  IsolatedContainer({
    String prefix = '',
    super.router,
    super.secureCookies,
    GetIt? container,
  })  : prefix = _normalizePrefix(prefix),
        super(
          container: container ?? GetIt.asNewInstance(),
        );

  /// Public prefix exposed for introspection (always normalised to leading slash
  /// without trailing slash, except when empty).
  final String prefix;

  final Map<String, dynamic> cache = {};

  /// Override addRoute to normalize paths for isolated containers.
  @override
  void addRoute(String method, String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    super.addRoute(method, _normalizeLocalPath(path), handler,
        middleware: middleware);
  }

  /// Mounts this container into the provided [app], delegating only requests
  /// whose path matches the configured prefix via the parent router. This keeps
  /// path normalisation and parameter extraction consistent with the main
  /// routing strategy.
  ///
  /// Sessions created via routes on this container are issued their own
  /// Set-Cookie using *this container's* [secureCookies] setting, not
  /// [app]'s — it defaults to `true` regardless of how [app] is configured.
  /// A mismatch (e.g. `app`'s `secureCookies: false` for local HTTP dev,
  /// paired with this container's default `true`) means the browser will
  /// silently discard the cookie over plain HTTP, so sessions touched from
  /// this container will appear not to persist. Pass a matching
  /// `secureCookies` value at construction to avoid this.
  void mount(Fletch app) {
    if (secureCookies != app.secureCookies) {
      logger.w(
          'IsolatedContainer mounted at "${prefix.isEmpty ? '/' : prefix}" '
          'has secureCookies: $secureCookies but the host app has '
          'secureCookies: ${app.secureCookies}. Session cookies issued from '
          'this container will use its own setting, not the host app\'s — '
          'if they mismatch, the browser may silently drop the cookie. '
          'Pass a matching secureCookies value to IsolatedContainer(...).');
    }
    final mountPrefix = prefix.isEmpty ? '/' : prefix;
    app.router.addIsolatedRouter(
      mountPrefix,
      _IsolatedRouterDelegate(this),
    );
  }

  /// Creates a copy of this container with a new prefix.
  ///
  /// This is useful when you want to mount the same container at different
  /// paths or when using the `app.mount()` convenience method.
  ///
  /// Note: This creates a shallow copy - the router and DI container are
  /// shared, so all routes and dependencies are the same.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final authModule = IsolatedContainer();
  /// authModule.get('/login', loginHandler);
  ///
  /// // Mount at different prefix
  /// app.mount('/auth', authModule.withPrefix('/auth'));
  /// ```
  IsolatedContainer withPrefix(String newPrefix) {
    return IsolatedContainer(
      prefix: newPrefix,
      router: router,
      container: container,
      secureCookies: secureCookies,
    );
  }

  /// Optional helper to run this container as a standalone service.
  Future<void> listen(
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
    logger.i('Isolated container listening on port ${server.port}');
    await for (final httpRequest in server) {
      await handleRequest(httpRequest);
    }
  }

  @override
  String resolveRoutePath(Request request) {
    if (prefix.isEmpty) return request.uri.path;

    final path = request.uri.path;
    if (path == prefix || path == '$prefix/') {
      return '/';
    }

    final prefixedWithSlash = prefix.isEmpty ? '/' : '$prefix/';
    if (path.startsWith(prefixedWithSlash)) {
      final trimmed = path.substring(prefix.length);
      if (trimmed.isEmpty) return '/';
      return trimmed.startsWith('/') ? trimmed : '/$trimmed';
    }

    return request.uri.path;
  }

  @override
  Future<void> onDispose() {
    cache.clear();
    return super.onDispose();
  }

  /// Public hook to process a scoped request inside this container.
  Future<void> handleScoped(Request request, Response response) {
    return processRequest(request, response);
  }

  static String _normalizeLocalPath(String path) {
    if (path.isEmpty) return '/';
    return path.startsWith('/') ? path : '/$path';
  }

  static String _normalizePrefix(String prefix) {
    var value = prefix.trim();
    if (value.isEmpty || value == '/') {
      return '';
    }
    if (!value.startsWith('/')) {
      value = '/$value';
    }
    if (value.endsWith('/') && value.length > 1) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}

class _IsolatedRouterDelegate implements RouterInterface {
  _IsolatedRouterDelegate(this.container);

  final IsolatedContainer container;

  @override
  void addRoute(String method, String path, RequestHandler handler) {
    container.router.addRoute(method, path, handler);
  }

  @override
  void addIsolatedRouter(String prefix, RouterInterface router) {
    container.router.addIsolatedRouter(prefix, router);
  }

  @override
  void clear() => container.router.clear();

  @override
  RouteMatch? findRoute(String method, String path) {
    final delegateMatch = container.router.findRoute(method, path);
    if (delegateMatch == null) {
      return null;
    }

    return RouteMatch(
      (parentRequest, parentResponse) async {
        // Reuse parent session and store for isolated containers.
        // This ensures session data is shared and persisted correctly.
        // We don't need to pass sessionStore again because we're sharing
        // the parent Session object which already has its store reference.
        final scopedRequest = Request(
          parentRequest.httpRequest,
          parentRequest.session.id, // ignored — existingSession takes priority
          parentRequest.requestId,
          container.container,
          // Without this, isSessionNew defaults to false, so a session
          // created for the first time via an isolated-container route
          // would never get a Set-Cookie issued — every request would
          // silently start a brand-new, unreachable server-side session.
          isSessionNew: parentRequest.isNewSession,
          existingSession: parentRequest.session, // share loaded session
          sessionSigner: parentRequest.sessionSigner,
        );

        await container.handleScoped(scopedRequest, parentResponse);
      },
      pathParams: delegateMatch.pathParams,
    );
  }
}
