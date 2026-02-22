import 'dart:async';

import 'package:watcher/watcher.dart';

/// Watches files for changes and triggers callbacks with debouncing.
class DevFileWatcher {
  final List<String> _watchDirs;
  final Duration _debounceDelay;
  final List<String> _ignorePatterns;

  DirectoryWatcher? _watcher;
  StreamSubscription? _subscription;
  Timer? _debounceTimer;

  /// Callback triggered when files change (after debouncing).
  final Future<void> Function(WatchEvent event) onChanged;

  DevFileWatcher({
    required List<String> watchDirectories,
    required this.onChanged,
    Duration debounceDelay = const Duration(milliseconds: 500),
    List<String> ignorePatterns = const [
      '.dart_tool',
      '.git',
      'build',
      '.packages',
      'pubspec.lock',
    ],
  })  : _watchDirs = watchDirectories,
        _debounceDelay = debounceDelay,
        _ignorePatterns = ignorePatterns;

  /// Start watching for file changes.
  Future<void> start() async {
    if (_watchDirs.isEmpty) {
      throw StateError('No directories to watch');
    }

    // For now, watch the first directory
    // TODO: Support multiple directories
    final watchDir = _watchDirs.first;

    print('👀 Watching: $watchDir');

    _watcher = DirectoryWatcher(watchDir);
    _subscription = _watcher!.events.listen(_handleEvent);
  }

  void _handleEvent(WatchEvent event) {
    // Ignore files matching patterns
    if (_shouldIgnore(event.path)) {
      return;
    }

    // Debounce: cancel previous timer and start new one
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      onChanged(event);
    });
  }

  bool _shouldIgnore(String path) {
    for (final pattern in _ignorePatterns) {
      if (path.contains(pattern)) {
        return true;
      }
    }
    return false;
  }

  /// Stop watching for file changes.
  Future<void> stop() async {
    _debounceTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    _watcher = null;
  }
}
