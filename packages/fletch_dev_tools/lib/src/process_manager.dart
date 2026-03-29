import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Manages the lifecycle of a Dart process for the dev server.
class ProcessManager {
  Process? _process;
  final String _entryPoint;
  final int _port;
  Uri? _vmServiceUri;
  File? _serviceInfoFile;

  ProcessManager({
    required String entryPoint,
    required int port,
  })  : _entryPoint = entryPoint,
        _port = port;

  /// The VM service URI for the currently running child process (if available).
  Uri? get vmServiceUri => _vmServiceUri;

  /// Start the Dart process with VM service enabled.
  Future<void> start() async {
    if (_process != null) {
      throw StateError('Process already running');
    }

    // Wait for port to be available
    await _waitForPortAvailable(_port);

    print('🚀 Starting server: $_entryPoint');

    // Write VM service info to a temp file so the dev wrapper can connect.
    _serviceInfoFile = await _createServiceInfoFile();

    // Run Dart VM DIRECTLY (not via 'dart run') to avoid orphaned processes
    _process = await Process.start(
      'dart',
      [
        '--enable-vm-service=0',
        '--write-service-info=${_serviceInfoFile!.path}',
        // NO 'run' command - execute directly!
        _entryPoint,
      ],
      environment: {
        'PORT': _port.toString(),
        'FLETCH_DEV_RELOAD': '1',
      },
    );

    // Pipe output to console
    _process!.stdout.listen((data) {
      stdout.add(data);
    });

    _process!.stderr.listen((data) {
      stderr.add(data);
    });

    // Read VM service URI from the info file — retries until the VM writes it.
    _vmServiceUri = await _readServiceUri();
    if (_vmServiceUri != null) {
      print('📡 VM service: $_vmServiceUri');
    }

    print('✅ Server started');
  }

  /// Stop the process and wait for it to actually exit.
  Future<void> stop() async {
    if (_process == null) {
      return;
    }

    print('🛑 Stopping server...');

    // Send SIGKILL
    _process!.kill(ProcessSignal.sigkill);

    // CRITICAL: Wait for exitCode to ensure process actually died
    try {
      final exitCode = await _process!.exitCode.timeout(
        Duration(seconds: 2),
        onTimeout: () {
          print('⚠️  Process didn\'t exit cleanly');
          return -1;
        },
      );
      print('🔍 Process exited with code: $exitCode');
    } catch (e) {
      print('⚠️  Error waiting for exit: $e');
    }

    _process = null;
    _vmServiceUri = null;
    await _cleanupServiceInfoFile();

    // Extra delay for OS to release port
    await Future.delayed(Duration(milliseconds: 300));

    print('✅ Server stopped');
  }

  /// Restart the process (stop then start).
  Future<void> restart() async {
    final stopwatch = Stopwatch()..start();
    await stop();
    await start();
    stopwatch.stop();
    print('⚡ Restarted in ${stopwatch.elapsedMilliseconds}ms');
  }

  /// Check if process is running.
  bool get isRunning => _process != null;

  Future<File> _createServiceInfoFile() async {
    final dir = Directory.systemTemp.createTempSync('fletch_dev_');
    return File('${dir.path}/vm_service.json');
  }

  Future<Uri?> _readServiceUri() async {
    final file = _serviceInfoFile;
    if (file == null) {
      print('⚠️  Service info file not created');
      return null;
    }

    // Retry until the service info file is written with a URI.
    const attempts = 50;
    for (var i = 0; i < attempts; i++) {
      try {
        if (!await file.exists()) {
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        final content = await file.readAsString();
        if (content.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        final data = jsonDecode(content);
        final uri = _extractUri(data);
        if (uri != null) {
          return uri;
        }
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    print('⚠️  Failed to read VM service URI from ${file.path}');
    return null;
  }

  Future<void> _cleanupServiceInfoFile() async {
    try {
      final file = _serviceInfoFile;
      if (file != null && await file.exists()) {
        final dir = file.parent;
        await file.delete();
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    } catch (_) {
      // Best effort cleanup.
    } finally {
      _serviceInfoFile = null;
    }
  }

  Uri? _extractUri(dynamic data) {
    if (data is String) {
      return _tryParseUri(data);
    }
    if (data is Map) {
      for (final entry in data.entries) {
        if (entry.key.toString().toLowerCase().contains('uri')) {
          final uri = _tryParseUri(entry.value?.toString() ?? '');
          if (uri != null) return uri;
        }
        final nested = _extractUri(entry.value);
        if (nested != null) return nested;
      }
    } else if (data is Iterable) {
      for (final item in data) {
        final uri = _extractUri(item);
        if (uri != null) return uri;
      }
    }
    return null;
  }

  Uri? _tryParseUri(String value) {
    if (value.isEmpty) return null;
    try {
      return Uri.parse(value);
    } catch (_) {
      return null;
    }
  }

  /// Wait for a port to become available.
  Future<void> _waitForPortAvailable(int port, {int maxAttempts = 15}) async {
    for (var i = 0; i < maxAttempts; i++) {
      try {
        // Try to bind to the port
        final server = await ServerSocket.bind('0.0.0.0', port);
        await server.close();
        // Port is available!
        return;
      } catch (e) {
        // Port is in use, wait and retry
        if (i < maxAttempts - 1) {
          await Future.delayed(Duration(milliseconds: 500));
        } else {
          print('⚠️  Port $port still in use after ${maxAttempts} attempts');
          print('   Trying to start anyway...');
        }
      }
    }
  }
}
