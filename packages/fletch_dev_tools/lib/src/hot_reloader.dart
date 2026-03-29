import 'dart:async';
import 'dart:convert';
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

        final isolates = vm.isolates!;
        IsolateRef? appIsolate;
        for (final isolateRef in isolates) {
          final isolateId = isolateRef.id;
          if (isolateId == null) continue;
          try {
            final isolate = await _vmService!.getIsolate(isolateId);
            final extensionRpcs = isolate.extensionRPCs ?? const <String>[];
            if (extensionRpcs.contains('ext.fletch.reload.runtimeState')) {
              appIsolate = isolateRef;
              break;
            }
          } catch (_) {
            // Ignore probe failures and continue scanning isolates.
          }
        }
        appIsolate ??= isolates.firstWhere(
          (isolate) => isolate.isSystemIsolate != true,
          orElse: () => isolates.first,
        );
        _isolateId = appIsolate.id!;
        _isConnected = true;
        return true;
      } catch (e) {
        await _vmService?.dispose().catchError((_) {});
        _vmService = null;

        if (attempt == maxAttempts) {
          print(
              '⚠️  Failed to connect to VM service after $maxAttempts attempts: $e');
          _isConnected = false;
          return false;
        }
        await Future.delayed(delay);
      }
    }
    return false;
  }

  /// Perform hot reload.
  Future<HotReloadResult> reload({
    List<String> changedFiles = const [],
    bool reassembleRoutes = true,
  }) async {
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
        if (reassembleRoutes) {
          await _reassemble();
        } else {
          if (changedFiles.isEmpty) {
            print('♻️  Incremental reload applied');
          } else {
            print(
              '♻️  Incremental reload applied for ${changedFiles.length} file(s) (no route reassemble)',
            );
          }
        }
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
      // Extension not registered — app didn't configure hot reload wiring.
      print(
        'ℹ️  Reassemble skipped (call app.hotReload(...) or configureDevHotReload(...)): $e',
      );
    }
  }

  Future<ActivateGenerationResult> activateGeneration(
    String generationId,
  ) async {
    final call = await _callJsonExtension(
      'ext.fletch.reload.activateGeneration',
      args: {
        'generationId': generationId,
      },
    );
    if (!call.available) {
      return ActivateGenerationResult(
        available: false,
        success: false,
        message: call.error ?? 'Generation activation extension unavailable',
        generationId: generationId,
      );
    }

    final payload = call.payload;
    final ok = payload != null && payload['ok'] == true;
    return ActivateGenerationResult(
      available: true,
      success: ok,
      message:
          payload?['error']?.toString() ?? (ok ? 'ok' : 'activation failed'),
      generationId: payload?['generationId']?.toString() ?? generationId,
    );
  }

  Future<RetireGenerationResult> retireGeneration(
    String generationId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final call = await _callJsonExtension(
      'ext.fletch.reload.retireGeneration',
      args: {
        'generationId': generationId,
        'timeoutMs': timeout.inMilliseconds.toString(),
      },
    );
    if (!call.available) {
      return RetireGenerationResult(
        available: false,
        success: false,
        message: call.error ?? 'Generation retire extension unavailable',
        generationId: generationId,
      );
    }

    final payload = call.payload;
    final ok = payload != null && payload['ok'] == true;
    return RetireGenerationResult(
      available: true,
      success: ok,
      message: payload?['error']?.toString() ?? (ok ? 'ok' : 'retire failed'),
      generationId: payload?['generationId']?.toString() ?? generationId,
      forced: payload?['forced'] == true,
      remainingInFlight: _asInt(payload?['remainingInFlight']),
      elapsedMs: _asInt(payload?['elapsedMs']),
    );
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

  Future<_ExtensionCallResult> _callJsonExtension(
    String method, {
    Map<String, String> args = const {},
  }) async {
    if (!_isConnected || _vmService == null || _isolateId == null) {
      return const _ExtensionCallResult(
        available: false,
        error: 'Not connected to VM service',
      );
    }

    try {
      final response = await _vmService!.callServiceExtension(
        method,
        isolateId: _isolateId,
        args: args,
      );
      final payload = decodeVmServiceExtensionPayload(response.json);
      if (payload != null) {
        return _ExtensionCallResult(
          available: true,
          payload: payload,
        );
      }
      return _ExtensionCallResult(
        available: true,
        error: 'Unexpected extension payload for $method',
      );
    } catch (e) {
      return _ExtensionCallResult(
        available: false,
        error: '$e',
      );
    }
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
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

class ActivateGenerationResult {
  final bool available;
  final bool success;
  final String message;
  final String generationId;

  const ActivateGenerationResult({
    required this.available,
    required this.success,
    required this.message,
    required this.generationId,
  });
}

class RetireGenerationResult {
  final bool available;
  final bool success;
  final String message;
  final String generationId;
  final bool forced;
  final int? remainingInFlight;
  final int? elapsedMs;

  const RetireGenerationResult({
    required this.available,
    required this.success,
    required this.message,
    required this.generationId,
    this.forced = false,
    this.remainingInFlight,
    this.elapsedMs,
  });
}

class _ExtensionCallResult {
  final bool available;
  final String? error;
  final Map<String, Object?>? payload;

  const _ExtensionCallResult({
    required this.available,
    this.error,
    this.payload,
  });
}

Map<String, Object?>? decodeVmServiceExtensionPayload(dynamic node) {
  if (node == null) return null;
  if (node is String) {
    try {
      final decoded = jsonDecode(node);
      return decodeVmServiceExtensionPayload(decoded);
    } catch (_) {
      return null;
    }
  }
  if (node is Map) {
    final map = Map<String, Object?>.from(node);
    if (map.containsKey('ok')) return map;
    if (map.containsKey('result')) {
      final nested = decodeVmServiceExtensionPayload(map['result']);
      if (nested != null) return nested;
    }
    if (map.containsKey('response')) {
      final nested = decodeVmServiceExtensionPayload(map['response']);
      if (nested != null) return nested;
    }
    return map;
  }
  return null;
}
