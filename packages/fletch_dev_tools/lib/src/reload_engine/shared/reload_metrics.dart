/// Metrics sink abstraction for reload engine internals.
abstract class ReloadMetricsSink {
  void incrementCounter(
    String name, {
    Map<String, String> labels = const {},
    int by = 1,
  });

  void observeMs(
    String name,
    num milliseconds, {
    Map<String, String> labels = const {},
  });

  void setGauge(
    String name,
    num value, {
    Map<String, String> labels = const {},
  });
}

/// Canonical metric names for reload runtime observability.
abstract final class ReloadMetricNames {
  static const reloadTransactionsTotal = 'reload_transactions_total';
  static const reloadCompileFailuresTotal = 'reload_compile_failures_total';
  static const reloadActivationFailuresTotal =
      'reload_activation_failures_total';
  static const reloadRollbacksTotal = 'reload_rollbacks_total';

  static const reloadDetectMs = 'reload_detect_ms';
  static const reloadClassifyMs = 'reload_classify_ms';
  static const reloadCompileMs = 'reload_compile_ms';
  static const reloadStageMs = 'reload_stage_ms';
  static const reloadActivateMs = 'reload_activate_ms';
  static const reloadTotalMs = 'reload_total_ms';

  static const reloadInflightRequests = 'reload_inflight_requests';
  static const reloadGenerationActiveAgeMs = 'reload_generation_active_age_ms';
  static const reloadQueueDepth = 'reload_queue_depth';
}

/// Default no-op metrics sink.
class NoopReloadMetricsSink implements ReloadMetricsSink {
  const NoopReloadMetricsSink();

  @override
  void incrementCounter(
    String name, {
    Map<String, String> labels = const {},
    int by = 1,
  }) {}

  @override
  void observeMs(
    String name,
    num milliseconds, {
    Map<String, String> labels = const {},
  }) {}

  @override
  void setGauge(
    String name,
    num value, {
    Map<String, String> labels = const {},
  }) {}
}
