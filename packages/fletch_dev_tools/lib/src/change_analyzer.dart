import 'dart:io';

import 'ast_change_analyzer.dart';

/// Decision about whether a file change can use hot reload or requires restart.
enum ReloadDecision {
  /// Change can be hot reloaded safely
  canHotReload,

  /// Change requires a full restart
  requiresRestart,
}

/// Result of analyzing a single file change — decision + changes bundled together
/// so the AST is only parsed once per file event.
class AnalysisResult {
  final ReloadDecision decision;
  final List<CodeChange> changes;
  final String reason;
  final bool requiresRouteReassemble;

  const AnalysisResult({
    required this.decision,
    required this.changes,
    required this.reason,
    this.requiresRouteReassemble = false,
  });
}

/// Analyzes file changes to determine if hot reload is safe.
class ChangeAnalyzer {
  final ASTChangeAnalyzer _astAnalyzer = ASTChangeAnalyzer();

  /// Analyze a file change once and return decision + changes together.
  /// Parses the AST exactly once per event — no double-analysis bug.
  Future<AnalysisResult> analyze(String path) async {
    // Quick checks for files that always require restart
    if (_alwaysRequiresRestart(path)) {
      return AnalysisResult(
        decision: ReloadDecision.requiresRestart,
        changes: [],
        reason: _quickRestartReason(path),
        requiresRouteReassemble: false,
      );
    }

    // For Dart files, run AST analysis exactly once
    if (path.endsWith('.dart')) {
      final changes = await _astAnalyzer.analyzeFile(path);

      if (changes.any((c) => c.requiresRestart)) {
        final reason = changes
            .where((c) => c.requiresRestart)
            .map((c) => c.description)
            .take(3)
            .join(', ');
        return AnalysisResult(
          decision: ReloadDecision.requiresRestart,
          changes: changes,
          reason: reason,
          requiresRouteReassemble: false,
        );
      }

      if (changes.isNotEmpty && changes.every((c) => c.isSafeForHotReload)) {
        return AnalysisResult(
          decision: ReloadDecision.canHotReload,
          changes: changes,
          reason: 'Body-only changes',
          requiresRouteReassemble: _requiresRouteReassemble(path),
        );
      }
    }

    return AnalysisResult(
      decision: ReloadDecision.requiresRestart,
      changes: [],
      reason: 'File changed',
      requiresRouteReassemble: false,
    );
  }

  /// Heuristic that decides if a hot reload should be followed by route
  /// reassembly. Files that appear to register routes should reassemble so
  /// updated handler bindings are applied.
  bool _requiresRouteReassemble(String path) {
    if (!path.endsWith('.dart')) return false;
    try {
      final content = File(path).readAsStringSync();
      final routeApiPattern = RegExp(
        r'\.(get|post|put|patch|delete|head|options|use|useController|mount)\s*\(',
      );
      return routeApiPattern.hasMatch(content) ||
          content.contains('.hotReload(') ||
          content.contains('configureDevHotReload(') ||
          content.contains('registerRoutes(');
    } catch (_) {
      // Safe fallback: if analysis can't read the file, preserve behavior by
      // reassembling routes after reload.
      return true;
    }
  }

  String _quickRestartReason(String path) {
    if (path.endsWith('pubspec.yaml')) return 'Dependencies changed';
    if (path.endsWith('.g.dart')) return 'Generated code changed';
    if (_isEntryPoint(path)) return 'Entry point changed';
    return 'File changed';
  }

  /// Check if file always requires restart regardless of content.
  bool _alwaysRequiresRestart(String path) {
    return path.endsWith('pubspec.yaml') ||
        path.endsWith('.g.dart') ||
        _isEntryPoint(path);
  }

  bool _isEntryPoint(String path) {
    final segments = path.replaceAll('\\', '/').split('/');
    // bin/anything.dart → always restart
    final inBin =
        segments.length >= 2 && segments[segments.length - 2] == 'bin';
    // a file literally named main.dart
    final isMain = segments.last == 'main.dart';
    return inBin || isMain;
  }
}
