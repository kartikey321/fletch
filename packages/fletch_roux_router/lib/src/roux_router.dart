import 'package:fletch/fletch.dart';
import 'package:fletch/src/router/router_interface.dart';
import 'package:roux/roux.dart' as roux;

/// A [RouterInterface] implementation backed by the [roux](https://pub.dev/packages/roux)
/// library.
///
/// ## When to use
///
/// Use [RouxRouter] when you need richer route syntax than the default
/// [RadixRouter] supports:
///
/// | Syntax | Example | Meaning |
/// |--------|---------|---------|
/// | Optional param | `/:id?` | zero or one segment |
/// | One-or-more | `/:path+` | one or more segments |
/// | Zero-or-more | `/:path*` | zero or more segments |
/// | Optional suffix | `/book{s}?` | literal optional chars |
/// | Optional group | `/users{/:id}?` | optional path segment |
///
/// ## Trade-off
///
/// [RouxRouter] is slower than [RadixRouter] for static routes because roux
/// normalises every path at lookup time regardless. Prefer [RadixRouter]
/// (the default) for maximum throughput when you only need `:param` and `*`.
///
/// ## Usage
///
/// ```dart
/// final app = Fletch(router: RouxRouter());
///
/// app.get('/users/:id?',    handler);  // optional
/// app.get('/files/:path+',  handler);  // one-or-more
/// ```
///
/// An optional [LRU cache](https://pub.dev/packages/roux) can be passed for
/// repeated-path workloads:
///
/// ```dart
/// final app = Fletch(router: RouxRouter(cacheSize: 512));
/// ```
class RouxRouter implements RouterInterface {
  /// Creates a [RouxRouter].
  ///
  /// [cacheSize] — when non-null, attaches a roux [LRUCache] of that capacity
  /// so repeated lookups for the same path skip the trie traversal. Effective
  /// when your traffic hits a small set of distinct paths repeatedly.
  /// Defaults to `null` (no cache).
  RouxRouter({int? cacheSize}) : _cacheSize = cacheSize {
    _router = _buildRouter();
  }

  final int? _cacheSize;

  late roux.Router<RequestHandler> _router;

  // Isolated sub-routers mounted at specific prefixes.
  // Sorted longest-first so more-specific prefixes match before shorter ones.
  final List<_IsolatedMount> _mounts = [];
  final Set<String> _mountPrefixes = {};

  // -------------------------------------------------------------------------
  // RouterInterface
  // -------------------------------------------------------------------------

  @override
  void addRoute(String method, String path, RequestHandler handler) {
    _router.add(path, handler, method: method);
  }

  @override
  RouteMatch? findRoute(String method, String path) {
    // Isolated sub-routers first — checked longest-prefix first.
    for (final mount in _mounts) {
      if (_matchesPrefix(path, mount.prefix)) {
        final remaining = path.substring(mount.prefix.length);
        return mount.router.findRoute(
          method,
          remaining.isEmpty ? '/' : remaining,
        );
      }
    }

    final match = _router.find(path, method: method);
    if (match == null) return null;
    return RouteMatch(
      match.data,
      pathParams: match.params.isEmpty
          ? null
          : Map<String, String>.from(match.params),
    );
  }

  @override
  void addIsolatedRouter(String prefix, RouterInterface router) {
    final normalizedPrefix = _normalizePrefix(prefix);

    if (_mountPrefixes.contains(normalizedPrefix)) {
      throw RouteConflictError(
        'Isolated router already exists at prefix: $normalizedPrefix',
      );
    }

    _mounts.add(_IsolatedMount(normalizedPrefix, router));
    _mountPrefixes.add(normalizedPrefix);

    // Keep longest prefix first so more-specific mounts win.
    _mounts.sort((a, b) => b.prefix.length.compareTo(a.prefix.length));
  }

  /// Clears all routes and mounted sub-routers.
  ///
  /// Called by the hot-reload reassemble cycle.
  @override
  void clear() {
    _router = _buildRouter();
    _mounts.clear();
    _mountPrefixes.clear();
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  roux.Router<RequestHandler> _buildRouter() => roux.Router<RequestHandler>(
    caseSensitive: true,
    cache: _cacheSize != null ? roux.LRUCache(_cacheSize) : null,
  );

  /// Returns true when [path] starts with [prefix] at a segment boundary.
  ///
  ///   _matchesPrefix('/api/users', '/api')  → true
  ///   _matchesPrefix('/apiv2',     '/api')  → false  (not a segment boundary)
  static bool _matchesPrefix(String path, String prefix) {
    if (prefix == '/') return path.startsWith('/');
    if (!path.startsWith(prefix)) return false;
    if (path.length == prefix.length) return true;
    return path[prefix.length] == '/';
  }

  /// Normalizes mount prefixes to a canonical form:
  /// - trims whitespace
  /// - ensures leading slash
  /// - removes trailing slash (except for root `/`)
  static String _normalizePrefix(String prefix) {
    var value = prefix.trim();
    if (value.isEmpty || value == '/') return '/';
    if (!value.startsWith('/')) value = '/$value';
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return value;
  }
}

class _IsolatedMount {
  final String prefix;
  final RouterInterface router;
  const _IsolatedMount(this.prefix, this.router);
}
