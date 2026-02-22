import 'package:meta/meta.dart';

import '../models/middleware.dart';
import 'base_container.dart';

/// Helper passed to controllers so they can register routes relative to their
/// configured prefix without duplicating boilerplate.
class ControllerOptions {
  late final BaseContainer _app;
  late final String _prefix;
  ControllerOptions(this._app, this._prefix);

  /// Registers a `GET` handler relative to the controller prefix.
  void get(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    final fullPath = _joinPaths(path);
    _app.get(fullPath, handler, middleware: middleware);
  }

  /// Registers a `POST` handler relative to the controller prefix.
  void post(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    final fullPath = _joinPaths(path);
    _app.post(fullPath, handler, middleware: middleware);
  }

  /// Registers a `PUT` handler relative to the controller prefix.
  void put(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    final fullPath = _joinPaths(path);
    _app.put(fullPath, handler, middleware: middleware);
  }

  /// Registers a `PATCH` handler relative to the controller prefix.
  void patch(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    final fullPath = _joinPaths(path);
    _app.patch(fullPath, handler, middleware: middleware);
  }

  /// Registers a `DELETE` handler relative to the controller prefix.
  void delete(String path, RequestHandler handler,
      {List<MiddlewareHandler>? middleware}) {
    final fullPath = _joinPaths(path);
    _app.delete(fullPath, handler, middleware: middleware);
  }

  String _joinPaths(String path) {
    if (_prefix.isEmpty) return path;
    if (path.startsWith('/')) path = path.substring(1);
    return '${_prefix.endsWith('/') ? _prefix : '$_prefix/'}$path';
  }
}

/// Base class for feature modules that register routes using
/// [ControllerOptions]. Override [registerRoutes] to declare handlers.
abstract class Controller {
  late final ControllerOptions _options;
  @mustCallSuper
  void initialize(BaseContainer app, {required String prefix}) {
    _options = ControllerOptions(app, prefix);
    registerRoutes(_options);
  }

  /// Subclasses implement this to register routes.
  void registerRoutes(ControllerOptions options);
}
