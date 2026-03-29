import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:fletch/fletch.dart';

class DevReloadRetireResult {
  final String generationId;
  final bool forced;
  final int remainingInFlight;
  final Duration elapsed;

  const DevReloadRetireResult({
    required this.generationId,
    required this.forced,
    required this.remainingInFlight,
    required this.elapsed,
  });
}

class DevReloadRuntimeState {
  String _activeGeneration;
  final Map<String, int> _inFlightByGeneration = <String, int>{};
  final Set<String> _retiringGenerations = <String>{};

  DevReloadRuntimeState({
    String initialGeneration = 'gen-000001',
  }) : _activeGeneration = initialGeneration {
    _inFlightByGeneration[initialGeneration] = 0;
  }

  String get activeGeneration => _activeGeneration;

  int inFlightFor(String generationId) =>
      _inFlightByGeneration[generationId] ?? 0;

  int get totalInFlight =>
      _inFlightByGeneration.values.fold<int>(0, (sum, value) => sum + value);

  Set<String> get retiringGenerations =>
      UnmodifiableSetView<String>(_retiringGenerations);

  String beginRequest() {
    final generationId = _activeGeneration;
    _inFlightByGeneration[generationId] = inFlightFor(generationId) + 1;
    return generationId;
  }

  void endRequest(String generationId) {
    final current = inFlightFor(generationId);
    if (current <= 1) {
      _inFlightByGeneration[generationId] = 0;
      return;
    }
    _inFlightByGeneration[generationId] = current - 1;
  }

  void activateGeneration(String generationId) {
    _activeGeneration = generationId;
    _inFlightByGeneration.putIfAbsent(generationId, () => 0);
  }

  Future<DevReloadRetireResult> retireGeneration(
    String generationId, {
    Duration timeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(milliseconds: 25),
  }) async {
    _retiringGenerations.add(generationId);
    final stopwatch = Stopwatch()..start();

    while (inFlightFor(generationId) > 0 && stopwatch.elapsed < timeout) {
      await Future<void>.delayed(pollInterval);
    }

    stopwatch.stop();
    final remaining = inFlightFor(generationId);
    final forced = remaining > 0;
    _retiringGenerations.remove(generationId);
    _inFlightByGeneration.remove(generationId);

    return DevReloadRetireResult(
      generationId: generationId,
      forced: forced,
      remainingInFlight: remaining,
      elapsed: stopwatch.elapsed,
    );
  }

  Map<String, Object?> snapshot() => {
        'activeGeneration': _activeGeneration,
        'totalInFlight': totalInFlight,
        'inFlightByGeneration': Map<String, int>.from(_inFlightByGeneration),
        'retiringGenerations': _retiringGenerations.toList(growable: false),
      };
}

class _DevReloadBinding {
  final Fletch app;
  final void Function() registerRoutes;
  final DevReloadRuntimeState runtime = DevReloadRuntimeState();

  _DevReloadBinding({
    required this.app,
    required this.registerRoutes,
  });

  void reassembleRoutes() {
    app.router.clear();
    registerRoutes();
  }

  void installRequestTrackingMiddleware() {
    app.use((req, res, next) async {
      final generation = runtime.beginRequest();
      try {
        await next();
      } finally {
        runtime.endRequest(generation);
      }
    });
  }
}

bool _extensionsRegistered = false;
_DevReloadBinding? _activeBinding;

/// Configure optional development-only route reassembly and runtime generation
/// extensions used by `fletch_dev_tools`.
///
/// This helper always runs [registerRoutes] once for startup. Extension wiring
/// is enabled only when [enabled] is true (or when the environment/compile-time
/// dev flag is present).
void configureDevHotReload(
  Fletch app, {
  required void Function() registerRoutes,
  bool? enabled,
}) {
  final shouldEnable = enabled ?? _defaultDevReloadEnabled();

  if (!shouldEnable) {
    registerRoutes();
    return;
  }

  final binding = _DevReloadBinding(
    app: app,
    registerRoutes: registerRoutes,
  );
  _activeBinding = binding;

  binding.installRequestTrackingMiddleware();
  binding.reassembleRoutes();

  if (_extensionsRegistered) return;
  _extensionsRegistered = true;
  _registerDevExtensions();
}

bool _defaultDevReloadEnabled() {
  const compileTimeEnabled = bool.fromEnvironment(
    'fletch.dev_reload',
    defaultValue: false,
  );
  if (compileTimeEnabled) return true;

  final value = Platform.environment['FLETCH_DEV_RELOAD']?.toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
}

void _registerDevExtensions() {
  _safeRegisterExtension('ext.fletch.reassemble', (method, params) async {
    final binding = _activeBinding;
    if (binding == null) {
      return _extensionResponse({
        'ok': false,
        'error': 'No active dev reload binding',
      });
    }

    binding.reassembleRoutes();
    return _extensionResponse({
      'ok': true,
      'type': '@Event',
      'kind': 'Reassembled',
    });
  });

  _safeRegisterExtension(
    'ext.fletch.reload.runtimeState',
    (method, params) async {
      final binding = _activeBinding;
      if (binding == null) {
        return _extensionResponse({
          'ok': false,
          'error': 'No active dev reload binding',
        });
      }

      return _extensionResponse({
        'ok': true,
        ...binding.runtime.snapshot(),
      });
    },
  );

  _safeRegisterExtension(
    'ext.fletch.reload.activateGeneration',
    (method, params) async {
      final binding = _activeBinding;
      if (binding == null) {
        return _extensionResponse({
          'ok': false,
          'error': 'No active dev reload binding',
        });
      }

      final generationId = params['generationId']?.trim();
      if (generationId == null || generationId.isEmpty) {
        return _extensionResponse({
          'ok': false,
          'error': 'Missing generationId',
        });
      }

      binding.runtime.activateGeneration(generationId);
      return _extensionResponse({
        'ok': true,
        'generationId': generationId,
        ...binding.runtime.snapshot(),
      });
    },
  );

  _safeRegisterExtension(
    'ext.fletch.reload.retireGeneration',
    (method, params) async {
      final binding = _activeBinding;
      if (binding == null) {
        return _extensionResponse({
          'ok': false,
          'error': 'No active dev reload binding',
        });
      }

      final generationId = params['generationId']?.trim();
      if (generationId == null || generationId.isEmpty) {
        return _extensionResponse({
          'ok': false,
          'error': 'Missing generationId',
        });
      }

      final timeoutMs = _parseDurationMs(
        params['timeoutMs'],
        fallback: 30000,
      );

      final result = await binding.runtime.retireGeneration(
        generationId,
        timeout: Duration(milliseconds: timeoutMs),
      );

      return _extensionResponse({
        'ok': true,
        'generationId': generationId,
        'forced': result.forced,
        'remainingInFlight': result.remainingInFlight,
        'elapsedMs': result.elapsed.inMilliseconds,
        ...binding.runtime.snapshot(),
      });
    },
  );
}

void _safeRegisterExtension(
  String method,
  Future<developer.ServiceExtensionResponse> Function(
    String method,
    Map<String, String> params,
  ) handler,
) {
  try {
    developer.registerExtension(method, handler);
  } catch (error) {
    final message = error.toString();
    if (message.contains('already registered')) {
      return;
    }
    rethrow;
  }
}

int _parseDurationMs(
  String? raw, {
  required int fallback,
}) {
  final parsed = int.tryParse(raw ?? '');
  final bounded = parsed ?? fallback;
  if (bounded < 1) return 1;
  if (bounded > 300000) return 300000;
  return bounded;
}

developer.ServiceExtensionResponse _extensionResponse(
  Map<String, Object?> payload,
) {
  return developer.ServiceExtensionResponse.result(jsonEncode(payload));
}
