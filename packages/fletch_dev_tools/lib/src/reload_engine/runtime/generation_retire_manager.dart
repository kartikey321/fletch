import 'dart:async';

import '../shared/reload_metrics.dart';
import 'active_generation_store.dart';

class GenerationRetireResult {
  final String generationId;
  final bool forced;
  final int remainingInFlight;
  final Duration elapsed;

  const GenerationRetireResult({
    required this.generationId,
    required this.forced,
    required this.remainingInFlight,
    required this.elapsed,
  });
}

/// Coordinates drain/retire behavior for a retiring generation.
class GenerationRetireManager {
  final ActiveGenerationStore _store;
  final ReloadMetricsSink _metrics;

  GenerationRetireManager(
    this._store, {
    ReloadMetricsSink metrics = const NoopReloadMetricsSink(),
  }) : _metrics = metrics;

  Future<GenerationRetireResult> retire(
    String generationId, {
    Duration timeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(milliseconds: 25),
  }) async {
    _store.markRetiring(generationId);
    final stopwatch = Stopwatch()..start();

    while (
        _store.inFlightFor(generationId) > 0 && stopwatch.elapsed < timeout) {
      await Future<void>.delayed(pollInterval);
    }

    stopwatch.stop();
    final remaining = _store.inFlightFor(generationId);
    final forced = remaining > 0;

    _store.completeRetire(generationId);
    _metrics.incrementCounter(
      'reload_generation_retire_total',
      labels: {
        'forced': forced.toString(),
      },
    );
    _metrics.observeMs(
      'reload_generation_retire_ms',
      stopwatch.elapsedMilliseconds,
      labels: {
        'forced': forced.toString(),
      },
    );

    return GenerationRetireResult(
      generationId: generationId,
      forced: forced,
      remainingInFlight: remaining,
      elapsed: stopwatch.elapsed,
    );
  }
}
