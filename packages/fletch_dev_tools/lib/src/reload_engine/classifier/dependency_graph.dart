import 'dart:io';

/// Graph-level impact derived from changed source files.
class DependencyImpact {
  final List<String> changedPaths;
  final List<String> invalidatedPaths;
  final bool routeGraphTouched;
  final bool containerShapeTouched;

  const DependencyImpact({
    required this.changedPaths,
    required this.invalidatedPaths,
    required this.routeGraphTouched,
    required this.containerShapeTouched,
  });
}

/// Incremental dependency graph used by classifier-v2 to expand invalidation
/// sets and detect route/DI touchpoints.
class DependencyGraphStore {
  final String _workspaceRoot;
  final String? _packageName;
  final Map<String, _DependencyNode> _nodes = {};

  DependencyGraphStore({
    String? workspaceRoot,
    String? packageName,
  })  : _workspaceRoot =
            (workspaceRoot ?? Directory.current.path).replaceAll('\\', '/'),
        _packageName = packageName;

  int get nodeCount => _nodes.length;

  Future<void> updateForPaths(Iterable<String> paths) async {
    for (final rawPath in paths) {
      final path = _normalizePath(rawPath);
      if (!path.endsWith('.dart')) continue;

      final file = File(path);
      if (!await file.exists()) {
        _removeNode(path);
        continue;
      }

      final content = await file.readAsString();
      _upsertNode(path, content);
    }
  }

  DependencyImpact planImpact(Iterable<String> changedPaths) {
    final changed = changedPaths.map(_normalizePath).toSet();
    final invalidated = <String>{...changed};
    final pending = <String>[...changed];

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final importedBy = _nodes[current]?.importedBy;
      if (importedBy == null || importedBy.isEmpty) continue;
      for (final dependent in importedBy) {
        if (invalidated.add(dependent)) {
          pending.add(dependent);
        }
      }
    }

    var routeGraphTouched = false;
    var containerShapeTouched = false;
    for (final path in invalidated) {
      final node = _nodes[path];
      if (node == null) continue;
      routeGraphTouched = routeGraphTouched || node.hasRouteTouchpoint;
      containerShapeTouched =
          containerShapeTouched || node.hasContainerTouchpoint;
      if (routeGraphTouched && containerShapeTouched) {
        break;
      }
    }

    final sortedChanged = changed.toList()..sort();
    final sortedInvalidated = invalidated.toList()..sort();
    return DependencyImpact(
      changedPaths: List.unmodifiable(sortedChanged),
      invalidatedPaths: List.unmodifiable(sortedInvalidated),
      routeGraphTouched: routeGraphTouched,
      containerShapeTouched: containerShapeTouched,
    );
  }

  void _upsertNode(String path, String content) {
    final previous = _nodes[path];
    final nextImports = _extractLocalImports(path, content);
    final hasRouteTouchpoint = _hasRouteTouchpoint(content);
    final hasContainerTouchpoint = _hasContainerTouchpoint(content);

    if (previous != null) {
      for (final imported in previous.imports) {
        _nodes[imported]?.importedBy.remove(path);
      }
    }

    final node = _nodes.putIfAbsent(path, () => _DependencyNode(path));
    node.imports
      ..clear()
      ..addAll(nextImports);
    node.hasRouteTouchpoint = hasRouteTouchpoint;
    node.hasContainerTouchpoint = hasContainerTouchpoint;

    for (final imported in nextImports) {
      final importedNode = _nodes.putIfAbsent(
        imported,
        () => _DependencyNode(imported),
      );
      importedNode.importedBy.add(path);
    }
  }

  void _removeNode(String path) {
    final node = _nodes.remove(path);
    if (node == null) return;
    for (final imported in node.imports) {
      _nodes[imported]?.importedBy.remove(path);
    }
    for (final dependent in node.importedBy) {
      _nodes[dependent]?.imports.remove(path);
    }
  }

  Set<String> _extractLocalImports(String sourcePath, String content) {
    final imports = <String>{};
    final pattern = RegExp(
      '^\\s*(?:import|export|part)\\s+[\'"]([^\'"]+)[\'"]',
      multiLine: true,
    );
    for (final match in pattern.allMatches(content)) {
      final rawUri = match.group(1);
      if (rawUri == null || rawUri.isEmpty) continue;
      final resolved = _resolveToLocalPath(sourcePath, rawUri);
      if (resolved != null) {
        imports.add(resolved);
      }
    }
    return imports;
  }

  bool _hasRouteTouchpoint(String content) {
    final routeApiPattern = RegExp(
      r'\.(get|post|put|patch|delete|head|options|use|useController|mount)\s*\(',
    );
    return routeApiPattern.hasMatch(content) ||
        content.contains('registerRoutes(') ||
        content.contains('.hotReload(') ||
        content.contains('configureDevHotReload(');
  }

  bool _hasContainerTouchpoint(String content) {
    final diPattern = RegExp(
      r'\b(register|bind|provide|singleton|factory|scoped)\b',
      caseSensitive: false,
    );
    return content.contains('DependencyContainer') ||
        content.contains('serviceLocator') ||
        content.contains('getIt') ||
        diPattern.hasMatch(content);
  }

  String? _resolveToLocalPath(String sourcePath, String rawUri) {
    if (rawUri.startsWith('dart:')) return null;
    if (rawUri.startsWith('package:')) {
      final packagePath = _resolvePackageUri(rawUri);
      if (packagePath == null) return null;
      return _normalizePath(packagePath);
    }

    final baseUri = File(sourcePath).absolute.uri;
    final resolved = baseUri.resolve(rawUri);
    if (resolved.scheme != 'file') return null;
    return _normalizePath(resolved.toFilePath());
  }

  String? _resolvePackageUri(String uri) {
    final packageName = _packageName;
    if (packageName == null) return null;
    final prefix = 'package:$packageName/';
    if (!uri.startsWith(prefix)) return null;

    final relative = uri.substring(prefix.length);
    if (relative.isEmpty) return null;
    return '$_workspaceRoot/lib/$relative';
  }

  String _normalizePath(String path) {
    return File(path).absolute.path.replaceAll('\\', '/');
  }
}

class _DependencyNode {
  final String path;
  final Set<String> imports = {};
  final Set<String> importedBy = {};
  bool hasRouteTouchpoint = false;
  bool hasContainerTouchpoint = false;

  _DependencyNode(this.path);
}
