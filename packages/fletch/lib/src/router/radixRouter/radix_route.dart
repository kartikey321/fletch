// radix_router.dart
import 'package:fletch/fletch.dart';
import 'package:fletch/src/router/router_interface.dart';

part 'radix_node.dart';

/// A high-performance router using a radix tree structure for efficient route matching.
///
/// Supports:
/// - Static routes (`/users/profile`)
/// - Parameter routes with optional regex constraints (`/users/:id(\d+)`)
/// - Wildcard parameters (`/users/:username`)
/// - Optional parameters (`/users/:id?` — registers both `/users` and `/users/:id`)
/// - Unnamed glob wildcards (`/static/*`)
/// - Named glob wildcards (`/static/*:rest` — captured into `req.params['rest']`)
///
/// Route matching priority per depth level:
///   1. Static segment (O(1) HashMap lookup)
///   2. Regex-constrained parameters (tried in registration order)
///   3. Plain wildcard parameters
///   4. Glob wildcard (`*` or `*:name`)
///
/// Fully-static routes additionally get an O(1) HashMap pre-check at the top of
/// [findRoute], so they never touch the radix tree at all.
class RadixRouter implements RouterInterface {
  final RadixNode _root = RadixNode.root();

  // O(1) fast path for fully-static routes (no `:param` or `*` segments).
  // Keyed by the normalised path with a leading `/` (matching uri.path).
  final Map<String, Map<String, RequestHandler>> _staticRoutes = {};

  static final _paramSegmentRe = RegExp(r':([a-zA-Z_]\w*)(?:\(([^)]+)\))?');
  static final _globNameRe = RegExp(r'^\*:([a-zA-Z_]\w*)$');
  static final _multiSlash = RegExp(r'/+');
  static final _trimSlash = RegExp(r'^/|/$');

  @override
  void addRoute(String method, String path, RequestHandler handler) {
    final normalizedPath = _normalizePath(path);

    // Expand optional params (`:name?`) into every concrete combination.
    // e.g. `users/:id?` → [`users/:id`, `users`]
    if (normalizedPath.contains('?')) {
      for (final expanded in _expandOptionals(normalizedPath)) {
        _addNormalizedRoute(method, expanded, handler);
      }
      return;
    }

    _addNormalizedRoute(method, normalizedPath, handler);
  }

  void _addNormalizedRoute(
      String method, String normalizedPath, RequestHandler handler) {
    final segments = _splitPath(normalizedPath);
    var currentNode = _root;

    for (final segment in segments) {
      currentNode = _getOrCreateNode(currentNode, segment);
    }

    if (currentNode.handlers.containsKey(method)) {
      throw RouteConflictError('Handler already exists for $method /$normalizedPath');
    }
    currentNode.handlers[method] = handler;

    // Index static-only routes for O(1) lookup (no `:` or `*` in path).
    if (!normalizedPath.contains(':') && !normalizedPath.contains('*')) {
      (_staticRoutes['/$normalizedPath'] ??= {})[method] = handler;
    }
  }

  /// Expands a path containing optional param segments (`:name?`) into all
  /// concrete combinations, preserving order (with-param before without).
  ///
  /// `/api/:version?/users` → [`api/:version/users`, `api/users`]
  List<String> _expandOptionals(String normalizedPath) {
    final segments = normalizedPath.split('/');
    var paths = <List<String>>[[]];

    for (final segment in segments) {
      final isOptional = segment.endsWith('?') && segment.startsWith(':');
      if (isOptional) {
        final required = segment.substring(0, segment.length - 1);
        final expanded = <List<String>>[];
        for (final p in paths) {
          expanded.add([...p, required]); // with this segment
          expanded.add([...p]);           // without this segment
        }
        paths = expanded;
      } else {
        for (final p in paths) {
          p.add(segment);
        }
      }
    }

    // Deduplicate while preserving order; join back to path strings.
    final seen = <String>{};
    return paths
        .map((p) => p.join('/'))
        .where(seen.add)
        .toList();
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
    // Fast path: O(1) HashMap lookup for fully-static routes.
    final staticHandlers = _staticRoutes[path];
    if (staticHandlers != null) {
      final handler = staticHandlers[method];
      if (handler != null) return RouteMatch(handler);
    }

    // Radix tree traversal for dynamic routes (params / wildcards / mounts).
    // Paths from dart:io HttpRequest.uri.path are already clean — no double
    // slashes, no trailing slash — so skip the allocating normalization step
    // on the hot path. Only normalize on addRoute (startup-time, not hot).
    final segments =
        _splitPath(path.startsWith('/') ? path.substring(1) : path);
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
    // Isolated sub-app — delegate remaining path to its own router.
    if (node.isolatedRouter != null && depth <= segments.length) {
      final remaining = segments.skip(depth);
      final remainingPath =
          remaining.isEmpty ? '' : remaining.join('/');
      return node.isolatedRouter!.findRoute(method, remainingPath);
    }

    // End of path — check for a handler on this node.
    if (depth == segments.length) {
      final handler = node.handlers[method];
      return handler != null ? RouteMatch(handler, pathParams: params) : null;
    }

    final segment = segments[depth];
    final nextDepth = depth + 1;

    // ── 1. Static children — O(1) direct lookup, no Iterable allocated ──────
    final staticChild = node.staticChildren?[segment];
    if (staticChild != null) {
      final match =
          _findRouteMatch(staticChild, segments, nextDepth, method, params);
      if (match != null) return match;
    }

    // ── 2. Regex-constrained param children ──────────────────────────────────
    final regexChildren = node.regexParamChildren;
    if (regexChildren != null) {
      for (final child in regexChildren) {
        if (child.regex!.hasMatch(segment)) {
          final backup = _handleParam(child, params, segment);
          final match =
              _findRouteMatch(child, segments, nextDepth, method, params);
          if (match != null) return match;
          _restoreParam(child, params, backup);
        }
      }
    }

    // ── 3. Plain wildcard param children ─────────────────────────────────────
    final wildcardChildren = node.wildcardParamChildren;
    if (wildcardChildren != null) {
      for (final child in wildcardChildren) {
        final backup = _handleParam(child, params, segment);
        final match =
            _findRouteMatch(child, segments, nextDepth, method, params);
        if (match != null) return match;
        _restoreParam(child, params, backup);
      }
    }

    // ── 4. Glob wildcard — consumes ALL remaining segments ───────────────────
    final globChild = node.globChild;
    if (globChild != null) {
      final handler = globChild.handlers[method];
      if (handler != null) {
        if (globChild.paramName != null) {
          // Named catch-all: capture everything from [depth] onward.
          params[globChild.paramName!] = segments.sublist(depth).join('/');
        }
        return RouteMatch(handler, pathParams: params);
      }
    }

    return null;
  }

  /// Returns the child node for [segment] under [parent], creating it if needed.
  ///
  /// Nodes are routed to the correct typed slot:
  ///   - `*` / `*:name` → [RadixNode.globChild]
  ///   - `:param(re)`   → [RadixNode.regexParamChildren]
  ///   - `:param`       → [RadixNode.wildcardParamChildren]
  ///   - literal        → [RadixNode.staticChildren]
  RadixNode _getOrCreateNode(RadixNode parent, String segment) {
    // ── Glob (unnamed `*` or named `*:rest`) ─────────────────────────────────
    if (segment == '*' || segment.startsWith('*:')) {
      if (parent.globChild != null) return parent.globChild!;
      String? paramName;
      if (segment.startsWith('*:')) {
        final m = _globNameRe.firstMatch(segment);
        if (m == null) throw FormatException('Invalid glob segment: $segment');
        paramName = m.group(1);
      }
      return parent.globChild = RadixNode.glob(paramName: paramName);
    }

    // ── Dynamic param ─────────────────────────────────────────────────────────
    if (segment.startsWith(':')) {
      final match = _paramSegmentRe.firstMatch(segment);
      if (match == null) {
        throw FormatException('Invalid path segment: $segment');
      }

      final paramName = match.group(1)!;
      final regexStr = match.group(2);

      if (regexStr != null) {
        // Regex-constrained param — reuse existing node for the same pattern.
        final list = parent.regexParamChildren ??= [];
        for (final node in list) {
          if (node.segment == segment) return node;
        }
        final node =
            RadixNode.dynamic(segment, paramName, RegExp('^$regexStr\$'));
        list.add(node);
        return node;
      } else {
        // Plain wildcard param — reuse existing node for the same segment.
        final list = parent.wildcardParamChildren ??= [];
        for (final node in list) {
          if (node.segment == segment) return node;
        }
        final node = RadixNode.dynamic(segment, paramName, null);
        list.add(node);
        return node;
      }
    }

    // ── Static ────────────────────────────────────────────────────────────────
    final children = parent.staticChildren ??= {};
    return children.putIfAbsent(segment, () => RadixNode.static(segment));
  }

  String _normalizePath(String path) => path
      .replaceAll(_multiSlash, '/')
      .replaceAll(_trimSlash, '');

  List<String> _splitPath(String path) => path.split('/');

  @override
  void clear() {
    _root.staticChildren = null;
    _root.regexParamChildren = null;
    _root.wildcardParamChildren = null;
    _root.globChild = null;
    _root.handlers.clear();
    _root.isolatedRouter = null;
    _staticRoutes.clear();
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
