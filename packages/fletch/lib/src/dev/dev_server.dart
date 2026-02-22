import 'dart:async';

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

    // Connect to VM service for hot reload
    await Future.delayed(Duration(seconds: 1));
    final connected =
        await _hotReloader.connect(serviceUri: _processManager.vmServiceUri);
    if (connected) {
      print('🔥 Hot reload enabled');
    } else {
      print('⚠️  Hot reload unavailable (using hot restart only)');
    }

    // Start watching for file changes
    await _fileWatcher.start();
  }

  /// Stop the development server.
  Future<void> stop() async {
    await _fileWatcher.stop();
    await _hotReloader.disconnect();
    await _processManager.stop();
  }

  /// Handle file change events.
  Future<void> _onFileChanged(WatchEvent event) async {
    print('');
    print('📝 File changed: ${event.path}');

    // Analyze the change
    final changeType = _changeAnalyzer.analyzeFile(event.path);
    final reason = _changeAnalyzer.getReason(changeType, event.path);

    // Try hot reload if possible
    if (changeType == ReloadDecision.canHotReload && _hotReloader.isConnected) {
      print('🔄 Hot reloading...');

      final result = await _hotReloader.reload();

      if (result.success) {
        print('✅ Hot reload successful (${result.duration}ms)');
        return;
      } else {
        print('⚠️  Hot reload failed: ${result.message}');
        print('🔄 Falling back to hot restart...');
      }
    } else {
      print('🔄 Hot restarting ($reason)...');
    }

    // Hot restart
    try {
      await _hotReloader.disconnect();
      await _processManager.restart();

      // Reconnect to VM service
      await Future.delayed(Duration(seconds: 1));
      await _hotReloader.connect(serviceUri: _processManager.vmServiceUri);
    } catch (e) {
      print('❌ Restart failed: $e');
    }
  }
}
