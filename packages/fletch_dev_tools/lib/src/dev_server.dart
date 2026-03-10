import 'dart:async';
import 'dart:io';

import 'package:watcher/watcher.dart';

import 'change_analyzer.dart';
import 'dev_file_watcher.dart';
import 'hot_reloader.dart';
import 'process_manager.dart';

/// Development server with hot restart and hot reload capabilities.
class FletchDevServer {
  final String _entryPoint;
  final int _port;
  final List<String> _watchDirs;

  late final ProcessManager _processManager;
  late final DevFileWatcher _fileWatcher;
  late final HotReloader _hotReloader;
  late final ChangeAnalyzer _changeAnalyzer;

  /// Guard against re-entrant change handling while a reload/restart is running.
  bool _busy = false;

  FletchDevServer({
    required String entryPoint,
    int port = 3000,
    List<String> watchDirectories = const ['lib'],
  })  : _entryPoint = entryPoint,
        _port = port,
        _watchDirs = watchDirectories {
    _processManager = ProcessManager(
      entryPoint: _entryPoint,
      port: _port,
    );

    _fileWatcher = DevFileWatcher(
      watchDirectories: _watchDirs,
      onChanged: _onFileChanged,
    );

    _hotReloader = HotReloader();
    _changeAnalyzer = ChangeAnalyzer();
  }

  /// Start the development server.
  Future<void> start() async {
    print('╔════════════════════════════════════════╗');
    print('║   Fletch Development Server            ║');
    print('╚════════════════════════════════════════╝');
    print('');
    print('📂 Watching: ${_watchDirs.join(', ')}');
    print('🚀 Entry: $_entryPoint');
    print('🔌 Port: $_port');
    print('');
    print('Press Ctrl+C to quit');
    print('');

    // Start the server process
    await _processManager.start();

    // Connect to VM service — retries until the child is ready
    final connected =
        await _hotReloader.connect(serviceUri: _processManager.vmServiceUri);
    if (connected) {
      print('🔥 Hot reload enabled');
    } else {
      print('⚠️  Hot reload unavailable (using hot restart only)');
    }

    // Pre-warm AST cache for all watched .dart files so the first file event
    // has something to diff against (otherwise first save always shows "File changed").
    await _prewarmAstCache();

    // Start watching for file changes
    await _fileWatcher.start();
  }

  /// Scans watched directories and runs a silent AST analysis on every .dart
  /// file to populate the cache before the watcher starts.
  Future<void> _prewarmAstCache() async {
    final dartFiles = <String>[];
    for (final dir in _watchDirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      await for (final entity in d.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          dartFiles.add(entity.path);
        }
      }
    }
    if (dartFiles.isNotEmpty) {
      // Analyze in parallel — we only care about populating the cache
      await Future.wait(dartFiles.map((f) => _changeAnalyzer.analyze(f)));
      print('🧠 AST cache warmed (${dartFiles.length} files)');
    }
  }

  /// Stop the development server.
  Future<void> stop() async {
    await _fileWatcher.stop();
    await _hotReloader.disconnect();
    await _processManager.stop();
  }

  /// Handle file change events with AST-based analysis.
  Future<void> _onFileChanged(WatchEvent event) async {
    if (_busy) return; // drop events while a reload/restart is in progress
    _busy = true;
    try {
      await _handleChange(event);
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleChange(WatchEvent event) async {
    print('');
    print('📝 File changed: ${event.path}');

    // Analyze once — decision + changes together (no double-parse)
    final result = await _changeAnalyzer.analyze(event.path);

    // Show detected changes
    if (result.changes.isNotEmpty) {
      print('🔍 Analyzing changes...');
      for (final change in result.changes.take(3)) {
        print('   $change');
        if (change.suggestion != null) {
          print('      💡 ${change.suggestion}');
        }
      }
      if (result.changes.length > 3) {
        print('   ... and ${result.changes.length - 3} more changes');
      }
    }

    // Try hot reload if safe
    if (result.decision == ReloadDecision.canHotReload &&
        _hotReloader.isConnected) {
      print('🔄 Hot reloading...');
      final reloadResult = await _hotReloader.reload();
      if (reloadResult.success) {
        print('✅ Hot reload successful (${reloadResult.duration}ms)');
        return;
      } else {
        print('⚠️  Hot reload failed: ${reloadResult.message}');
        print('🔄 Falling back to hot restart...');
      }
    } else {
      print('🔄 Hot restarting (${result.reason})...');
    }

    // Hot restart
    try {
      await _hotReloader.disconnect();
      await _processManager.restart();
      await _hotReloader.connect(serviceUri: _processManager.vmServiceUri);
    } catch (e) {
      print('❌ Restart failed: $e');
    }
  }
}
