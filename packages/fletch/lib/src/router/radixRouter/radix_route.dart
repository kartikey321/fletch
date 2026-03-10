// radix_router.dart
import 'package:fletch/fletch.dart';
import 'package:fletch/src/router/router_interface.dart';

part 'radix_node.dart';

/// A high-performance router using a radix tree structure for efficient route matching.
/// Supports:
/// - Static routes (/users/profile)
/// - Parameter routes with regex constraints (/users/:id(\d+))
/// - Wildcard parameters (/users/:username)
///
/// Route matching priority:
/// 1. Static routes
/// 2. Regex-constrained parameters
/// 3. Wildcard parameters
class RadixRouter implements RouterInterface {
  final RadixNode _root = RadixNode.root();

  @override
  void addRoute(String method, String path, RequestHandler handler) {
    final normalizedPath = _normalizePath(path);

    final segments = _splitPath(normalizedPath);
    var currentNode = _root;

    for (final segment in segments) {
      currentNode = _getOrCreateNode(currentNode, segment);
    }

    if (currentNode.handlers.containsKey(method)) {
      throw RouteConflictError('Handler already exists for $method $path');
    }
    currentNode.handlers[method] = handler;
  }

  @override
  void addIsolatedRouter(String prefix, RouterInterface router) {
    final normalizedPrefix = _normalizePath(prefix);
    final segments = _splitPath(normalizedPrefix);

    var currentNode = _root;
    for (final segment in segments) {
      currentNode = _getOrCreateNode(currentNode, segment);
    }

    if (currentNode.isolatedRouter != null) {
      throw RouteConflictError(
          'Isolated router already exists at prefix: $prefix');
    }
    currentNode.isolatedRouter = router;
  }

  @override
  RouteMatch? findRoute(String method, String path) {
    // Paths from dart:io HttpRequest.uri.path are already clean — no double
    // slashes, no trailing slash — so skip the allocating normalization step
    // on the hot path. Only normalize on addRoute (startup-time, not hot).
    final segments = _splitPath(path.startsWith('/') ? path.substring(1) : path);
    final params = <String, String>{};

    return _findRouteMatch(_root, segments, 0, method, params);
  }

  RouteMatch? _findRouteMatch(
    RadixNode node,
    List<String> segments,
    int depth,
    String method,
    Map<String, String> params,
  ) {
    // Check if current node has an isolated router
    if (node.isolatedRouter != null && depth <= segments.length) {
      final remainingSegments = segments.skip(depth);
      final remainingPath =
          remainingSegments.isEmpty ? '' : remainingSegments.join('/');
      return node.isolatedRouter!.findRoute(method, remainingPath);
    }

    // End of path - check for handler
    if (depth == segments.length) {
      final handler = node.handlers[method];
      return handler != null ? RouteMatch(handler, pathParams: params) : null;
    }

    final segment = segments[depth];
    final nextDepth = depth + 1;

    // Static routes first — children map is keyed by segment so at most one
    // static child can match; no need for a "processed" exclusion list.
    for (final child in node.children.values) {
      if (child.isStatic && child.segment == segment) {
        final match = _findRouteMatch(child, segments, nextDepth, method, params);
        if (match != null) return match;
        break; // unique key; no other static child can match this segment
      }
    }

    // Then regex routes
    for (final child in node.children.values) {
      if (child.isRegex && child.regex!.hasMatch(segment)) {
        final paramBackup = _handleParam(child, params, segment);
        final match = _findRouteMatch(child, segments, nextDepth, method, params);
        if (match != null) return match;
        _restoreParam(child, params, paramBackup);
      }
    }

    // Finally wildcard routes
    for (final child in node.children.values) {
      if (child.isWildcard) {
        final paramBackup = _handleParam(child, params, segment);
        final match = _findRouteMatch(child, segments, nextDepth, method, params);
        if (match != null) return match;
        _restoreParam(child, params, paramBackup);
      }
    }

    return null;
  }

  RadixNode _getOrCreateNode(RadixNode parent, String segment) {
    if (parent.children.containsKey(segment)) {
      return parent.children[segment]!;
    }

    final newNode = _createNode(segment);
    parent.children[segment] = newNode;
    return newNode;
  }

  RadixNode _createNode(String segment) {
    if (segment.startsWith(':')) {
      final match =
          RegExp(r':([a-zA-Z_]\w*)(?:\(([^)]+)\))?').firstMatch(segment);
      if (match == null) {
        throw FormatException('Invalid path segment: $segment');
      }

      final paramName = match.group(1)!;
      final regex =
          match.group(2) != null ? RegExp('^${match.group(2)}\$') : null;

      return RadixNode.dynamic(segment, paramName, regex);
    }
    return RadixNode.static(segment);
  }

  static final _multiSlash = RegExp(r'/+');
  static final _trimSlash = RegExp(r'^/|/$');

  String _normalizePath(String path) => path
      .replaceAll(_multiSlash, '/') // Collapse multiple slashes
      .replaceAll(_trimSlash, ''); // Trim leading/trailing slashes

  List<String> _splitPath(String path) => path.split('/');

  @override
  void clear() {
    _root.children.clear();
    _root.handlers.clear();
    _root.isolatedRouter = null;
  }

  String? _handleParam(
      RadixNode node, Map<String, String> params, String value) {
    if (!node.isDynamic) return null;
    final backup = params[node.paramName!];
    params[node.paramName!] = value;
    return backup;
  }

  void _restoreParam(
      RadixNode node, Map<String, String> params, String? backup) {
    if (!node.isDynamic) return;
    if (backup != null) {
      params[node.paramName!] = backup;
    } else {
      params.remove(node.paramName!);
    }
  }
}
