import 'dart:async';

import 'package:watcher/watcher.dart';

/// Watches files for changes and triggers callbacks with debouncing.
class DevFileWatcher {
  final List<String> _watchDirs;
  final Duration _debounceDelay;
  final List<String> _ignorePatterns;

  final List<StreamSubscription> _subscriptions = [];
  Timer? _debounceTimer;
  final Map<String, WatchEvent> _pendingByPath = {};

  /// Callback triggered with a coalesced batch of file changes
  /// after debouncing.
  final Future<void> Function(List<WatchEvent> events) onChanged;

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

  /// Start watching all configured directories.
  Future<void> start() async {
    if (_watchDirs.isEmpty) {
      throw StateError('No directories to watch');
    }

    for (final dir in _watchDirs) {
      print('👀 Watching: $dir');
      final sub = DirectoryWatcher(dir).events.listen(_handleEvent);
      _subscriptions.add(sub);
    }
  }

  void _handleEvent(WatchEvent event) {
    if (_shouldIgnore(event.path)) return;
    _pendingByPath[event.path] = event;

    // Debounce: cancel previous timer and start new one
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      final batch = _pendingByPath.values.toList(growable: false);
      _pendingByPath.clear();
      if (batch.isEmpty) return;
      onChanged(batch);
    });
  }

  bool _shouldIgnore(String path) {
    for (final pattern in _ignorePatterns) {
      if (path.contains(pattern)) return true;
    }
    return false;
  }

  /// Stop watching all directories.
  Future<void> stop() async {
    _debounceTimer?.cancel();
    _pendingByPath.clear();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }
}
