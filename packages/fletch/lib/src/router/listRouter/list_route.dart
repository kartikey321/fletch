// list_router.dart
import 'package:fletch/fletch.dart';
import 'package:fletch/src/router/router_interface.dart';

part 'route_entry.dart';

class ListRouter implements RouterInterface {
  final Map<String, _RouteEntry> _isolatedRoutes = {};
  final List<_RouteEntry> _routes = [];

  @override
  void addRoute(String method, String path, RequestHandler handler) {
    _routes.add(_RouteEntry.route(method, path, handler));
  }

  @override
  void addIsolatedRouter(String prefix, RouterInterface router) {
    if (_isolatedRoutes.containsKey(prefix)) {
      throw RouteConflictError(
          'Isolated router already exists at prefix: $prefix');
    }
    _isolatedRoutes[prefix] = _RouteEntry.isolated(prefix, router);
  }

  @override
  void clear() {
    _routes.clear();
    _isolatedRoutes.clear();
  }

  @override
  RouteMatch? findRoute(String method, String path) {
    // First check isolated routers
    for (final entry in _isolatedRoutes.values) {
      if (path.startsWith(entry.prefix!)) {
        final remainingPath = path.substring(entry.prefix!.length);
        final normalizedPath = remainingPath.isEmpty ? '' : remainingPath;
        return entry.isolatedRouter!.findRoute(method, normalizedPath);
      }
    }

    // Then check regular routes
    for (var route in _routes) {
      if (route.matches(method, path)) {
        return RouteMatch(
          route.handler,
          pathParams: route.extractParams(path),
        );
      }
    }
    return null;
  }
}
