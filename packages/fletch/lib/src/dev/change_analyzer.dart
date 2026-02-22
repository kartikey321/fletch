/// Analyzes file changes to determine if hot reload is safe.
class ChangeAnalyzer {
  /// Analyze a file change and determine the appropriate action.
  ReloadDecision analyzeFile(String path) {
    // Main file changes always need restart
    if (path.contains('main.dart') || path.contains('bin/')) {
      return ReloadDecision.requiresRestart;
    }

    // Pubspec changes need restart
    if (path.contains('pubspec.yaml') || path.contains('pubspec.lock')) {
      return ReloadDecision.requiresRestart;
    }

    // Generated files need restart
    if (path.contains('.g.dart') || path.contains('.freezed.dart')) {
      return ReloadDecision.requiresRestart;
    }

    // Most other changes can try hot reload
    return ReloadDecision.canHotReload;
  }

  /// Get human-readable reason for the change type.
  String getReason(ReloadDecision type, String path) {
    switch (type) {
      case ReloadDecision.canHotReload:
        return 'Code change detected';
      case ReloadDecision.requiresRestart:
        if (path.contains('main.dart') || path.contains('bin/')) {
          return 'Entry point changed';
        } else if (path.contains('pubspec')) {
          return 'Dependencies changed';
        } else if (path.contains('.g.dart')) {
          return 'Generated code changed';
        }
        return 'Structural change detected';
    }
  }
}

/// Type of change detected.
enum ReloadDecision {
  /// Change can be hot reloaded.
  canHotReload,

  /// Change requires full restart.
  requiresRestart,
}
