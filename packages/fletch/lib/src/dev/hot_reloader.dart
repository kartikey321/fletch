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

  /// Connect to the Dart VM service.
  Future<bool> connect({Uri? serviceUri}) async {
    try {
      // Use provided VM service URI (from child process) when available.
      Uri? uri = serviceUri;
      if (uri == null) {
        // Fallback to the current process VM service (only works if enabled).
        final info = await developer.Service.getInfo();
        uri = info.serverUri;
      }

      if (uri == null) {
        print('⚠️  VM service URI not available');
        return false;
      }

      print('🔌 Connecting to VM service: $uri');

      // Convert HTTP URI to WebSocket URI
      final wsUri = _toWsUri(uri);

      // Connect to VM service
      _vmService = await vmServiceConnectUri(wsUri);

      // Get main isolate
      final vm = await _vmService!.getVM();
      if (vm.isolates == null || vm.isolates!.isEmpty) {
        print('⚠️  No isolates found');
        return false;
      }

      _isolateId = vm.isolates!.first.id!;
      _isConnected = true;

      return true;
    } catch (e) {
      print('⚠️  Failed to connect to VM service: $e');
      _isConnected = false;
      return false;
    }
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
