import 'dart:async';
import 'dart:developer' as developer;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Manages hot reload via Dart VM service.
class HotReloader {
  VmService? _vmService;
  String? _isolateId;
  bool _isConnected = false;

  /// Whether hot reload is available.
  bool get isConnected => _isConnected;

  /// Connect to the Dart VM service, retrying until the child process is ready.
  Future<bool> connect({
    Uri? serviceUri,
    int maxAttempts = 20,
    Duration delay = const Duration(milliseconds: 300),
  }) async {
    Uri? uri = serviceUri;
    if (uri == null) {
      final info = await developer.Service.getInfo();
      uri = info.serverUri;
    }

    if (uri == null) {
      print('⚠️  VM service URI not available');
      return false;
    }

    print('🔌 Connecting to VM service: $uri');
    final wsUri = _toWsUri(uri);

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _vmService = await vmServiceConnectUri(wsUri);

        final vm = await _vmService!.getVM();
        if (vm.isolates == null || vm.isolates!.isEmpty) {
          throw StateError('No isolates found');
        }

        _isolateId = vm.isolates!.first.id!;
        _isConnected = true;
        return true;
      } catch (e) {
        await _vmService?.dispose().catchError((_) {});
        _vmService = null;

        if (attempt == maxAttempts) {
          print('⚠️  Failed to connect to VM service after $maxAttempts attempts: $e');
          _isConnected = false;
          return false;
        }
        await Future.delayed(delay);
      }
    }
    return false;
  }

  /// Perform hot reload.
  Future<HotReloadResult> reload() async {
    if (!_isConnected || _vmService == null || _isolateId == null) {
      return HotReloadResult(
        success: false,
        message: 'Not connected to VM service',
      );
    }

    try {
      final stopwatch = Stopwatch()..start();

      final result = await _vmService!.reloadSources(
        _isolateId!,
        force: false,
        pause: false,
      );

      stopwatch.stop();

      if (result.success ?? false) {
        await _reassemble();
        return HotReloadResult(
          success: true,
          message: 'Hot reload successful',
          duration: stopwatch.elapsedMilliseconds,
        );
      } else {
        return HotReloadResult(
          success: false,
          message: 'Hot reload failed',
        );
      }
    } catch (e) {
      return HotReloadResult(
        success: false,
        message: 'Hot reload error: $e',
      );
    }
  }

  /// Calls the `ext.fletch.reassemble` service extension in the target isolate
  /// so routes are cleared and re-registered with updated function references.
  Future<void> _reassemble() async {
    try {
      await _vmService!.callServiceExtension(
        'ext.fletch.reassemble',
        isolateId: _isolateId,
      );
      print('🔄 Routes reassembled');
    } catch (e) {
      // Extension not registered — app didn't call app.hotReload()
      print('ℹ️  Reassemble skipped (call app.hotReload() to enable): $e');
    }
  }

  /// Disconnect from VM service.
  Future<void> disconnect() async {
    try {
      await _vmService?.dispose();
    } catch (e) {
      // Ignore errors on disconnect
    }

    _vmService = null;
    _isolateId = null;
    _isConnected = false;
  }

  String _toWsUri(Uri uri) {
    if (uri.scheme.startsWith('ws')) {
      return uri.toString();
    }
    final http = uri.toString();
    final base = http.endsWith('/') ? http : '$http/';
    return base.replaceFirst(RegExp('^http'), 'ws') + 'ws';
  }
}

/// Result of a hot reload operation.
class HotReloadResult {
  final bool success;
  final String message;
  final int? duration;

  HotReloadResult({
    required this.success,
    required this.message,
    this.duration,
  });
}
