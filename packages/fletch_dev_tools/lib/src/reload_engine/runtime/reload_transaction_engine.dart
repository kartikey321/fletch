import 'dart:async';

import '../classifier/change_set.dart';
import '../shared/reload_metrics.dart';
import '../transaction/generation_id.dart';
import '../transaction/reload_phase.dart';
import '../transaction/reload_strategy.dart';
import '../transaction/reload_transaction.dart';
import '../transaction/reload_transaction_journal.dart';
import 'reload_engine.dart';
import 'reload_event.dart';

/// Transaction engine for reload lifecycle modeling with append-only journaling
/// and startup recovery.
class ReloadTransactionEngine implements ReloadEngine {
  final ReloadMetricsSink _metrics;
  final ReloadTransactionJournal? _journal;
  final StreamController<ReloadEvent> _eventsController =
      StreamController<ReloadEvent>.broadcast();
  final Map<String, ReloadTransaction> _latestByTransactionId = {};

  bool _running = false;
  int _txCounter = 0;
  int _generationSequence = 1;
  GenerationId _activeGeneration = const GenerationId('gen-000001');

  ReloadTransactionEngine({
    ReloadMetricsSink metrics = const NoopReloadMetricsSink(),
    ReloadTransactionJournal? journal,
  })  : _metrics = metrics,
        _journal = journal;

  @override
  bool get isRunning => _running;

  int get activeTransactionCount => _latestByTransactionId.length;

  @override
  Stream<ReloadEvent> get events => _eventsController.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _metrics.incrementCounter('reload_engine_lifecycle_total', labels: {
      'action': 'start',
    });
    await _recoverIncompleteTransactions();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _metrics.incrementCounter('reload_engine_lifecycle_total', labels: {
      'action': 'stop',
    });
    await _eventsController.close();
    _latestByTransactionId.clear();
  }

  @override
  Future<ReloadTransaction> submit(
    ChangeSet changeSet, {
    required ReloadStrategy strategy,
    String? message,
    DateTime? now,
  }) async {
    if (changeSet.isEmpty) {
      throw StateError('Cannot submit empty change set');
    }
    final tx = await createTransaction(
      generationFrom: _activeGeneration,
      generationTo: _reserveNextGeneration(),
      strategy: strategy,
      now: now,
    );
    return advanceTransaction(
      tx,
      ReloadPhase.classifying,
      message: message ??
          'Submitted ${changeSet.changedPaths.length} changed path(s)',
      now: now,
    );
  }

  /// Builds a detected transaction and emits a lifecycle event.
  Future<ReloadTransaction> createTransaction({
    required GenerationId generationFrom,
    required GenerationId generationTo,
    required ReloadStrategy strategy,
    DateTime? now,
  }) async {
    if (!_running) {
      throw StateError('Reload engine is not running');
    }
    _syncGenerationSequence(generationFrom);
    _syncGenerationSequence(generationTo);

    _txCounter++;
    final tx = ReloadTransaction.detected(
      transactionId: 'tx-${_txCounter.toString().padLeft(6, '0')}',
      generationFrom: generationFrom,
      generationTo: generationTo,
      strategy: strategy,
      now: now,
    );
    _cacheLatest(tx);
    await _persist(tx);
    _emitEvent(
      tx,
      type: ReloadEventType.lifecycle,
      message: 'Transaction detected',
    );
    return tx;
  }

  /// Phase transition helper used by the control-plane adapter.
  Future<ReloadTransaction> advanceTransaction(
    ReloadTransaction transaction,
    ReloadPhase next, {
    String? message,
    DateTime? now,
  }) async {
    final current =
        _latestByTransactionId[transaction.transactionId] ?? transaction;
    if (current.phase.isTerminal) return current;
    if (current.phase == next) return current;

    final updated = current.transitionTo(
      next,
      message: message,
      now: now,
    );
    _cacheLatest(updated);
    if (updated.phase == ReloadPhase.committed) {
      _activeGeneration = updated.generationTo;
      _syncGenerationSequence(updated.generationTo);
    }
    await _persist(updated);
    _emitEvent(
      updated,
      type: _eventTypeForPhase(next),
      message: message,
    );
    return updated;
  }

  /// Runs a synthetic happy-path transaction for testing.
  Future<ReloadTransaction> simulateHappyPath({
    required ChangeSet changeSet,
    required GenerationId generationFrom,
    required GenerationId generationTo,
    required ReloadStrategy strategy,
    DateTime? now,
  }) async {
    if (changeSet.isEmpty) {
      throw StateError('Cannot process empty change set');
    }

    final startedAt = DateTime.now();
    var tx = await createTransaction(
      generationFrom: generationFrom,
      generationTo: generationTo,
      strategy: strategy,
      now: now,
    );
    for (final phase in [
      ReloadPhase.classifying,
      ReloadPhase.compiling,
      ReloadPhase.staging,
      ReloadPhase.activating,
      ReloadPhase.retiring,
      ReloadPhase.committed,
    ]) {
      tx = await advanceTransaction(tx, phase);
    }
    _metrics.observeMs(
      'reload_engine_simulated_total_ms',
      DateTime.now().difference(startedAt).inMilliseconds,
    );
    return tx;
  }

  Future<ReloadTransaction> failTransaction(
    ReloadTransaction tx, {
    String message = 'Reload transaction failed',
  }) async {
    final current = _latestByTransactionId[tx.transactionId] ?? tx;
    final failed = current.phase.isTerminal
        ? current
        : await advanceTransaction(
            current,
            ReloadPhase.failed,
            message: message,
          );
    _metrics
        .incrementCounter(ReloadMetricNames.reloadTransactionsTotal, labels: {
      'status': 'failed',
      'strategy': tx.strategy.name,
    });
    return failed;
  }

  Future<List<ReloadTransaction>> _recoverIncompleteTransactions() async {
    final journal = _journal;
    if (journal == null) return const [];

    final entries = await journal.readAll();
    if (entries.isEmpty) return const [];

    final latestByTx = <String, ReloadTransaction>{};
    var maxCounter = 0;
    for (final entry in entries) {
      latestByTx[entry.transactionId] = entry;
      maxCounter =
          _maxCounterFromTransactionId(entry.transactionId, maxCounter);
      _syncGenerationSequence(entry.generationFrom);
      _syncGenerationSequence(entry.generationTo);
    }
    _txCounter = maxCounter;
    _latestByTransactionId.clear();

    final committed = latestByTx.values
        .where((tx) => tx.phase == ReloadPhase.committed)
        .toList(growable: false)
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    if (committed.isNotEmpty) {
      _activeGeneration = committed.last.generationTo;
    }

    final recovered = <ReloadTransaction>[];
    for (final tx in latestByTx.values) {
      if (tx.phase.isTerminal) continue;
      final aborted = tx.transitionTo(
        ReloadPhase.aborted,
        message:
            'Recovered on startup: previous process exited mid-transaction',
      );
      _cacheLatest(aborted);
      await _persist(aborted);
      _emitEvent(
        aborted,
        type: ReloadEventType.aborted,
        message: aborted.message,
      );
      recovered.add(aborted);
    }

    if (recovered.isNotEmpty) {
      _metrics.incrementCounter(
        'reload_recovered_transactions_total',
        by: recovered.length,
      );
    }
    return recovered;
  }

  Future<void> _persist(ReloadTransaction transaction) async {
    final journal = _journal;
    if (journal == null) return;
    await journal.append(transaction);
  }

  void _cacheLatest(ReloadTransaction transaction) {
    if (transaction.phase.isTerminal) {
      _latestByTransactionId.remove(transaction.transactionId);
      return;
    }
    _latestByTransactionId[transaction.transactionId] = transaction;
  }

  ReloadEventType _eventTypeForPhase(ReloadPhase phase) {
    switch (phase) {
      case ReloadPhase.committed:
        return ReloadEventType.committed;
      case ReloadPhase.failed:
        return ReloadEventType.failed;
      case ReloadPhase.aborted:
        return ReloadEventType.aborted;
      case ReloadPhase.detected:
        return ReloadEventType.lifecycle;
      case ReloadPhase.classifying:
      case ReloadPhase.compiling:
      case ReloadPhase.staging:
      case ReloadPhase.activating:
      case ReloadPhase.retiring:
        return ReloadEventType.phaseChanged;
    }
  }

  int _maxCounterFromTransactionId(String id, int current) {
    if (!id.startsWith('tx-')) return current;
    final raw = id.substring(3);
    final parsed = int.tryParse(raw);
    if (parsed == null) return current;
    return parsed > current ? parsed : current;
  }

  void _syncGenerationSequence(GenerationId id) {
    if (!id.value.startsWith('gen-')) return;
    final raw = id.value.substring(4);
    final parsed = int.tryParse(raw);
    if (parsed == null) return;
    if (parsed > _generationSequence) {
      _generationSequence = parsed;
    }
  }

  GenerationId _reserveNextGeneration() {
    _generationSequence++;
    return GenerationId(
        'gen-${_generationSequence.toString().padLeft(6, '0')}');
  }

  void _emitEvent(
    ReloadTransaction tx, {
    required ReloadEventType type,
    String? message,
  }) {
    _eventsController.add(
      ReloadEvent(
        type: type,
        transactionId: tx.transactionId,
        generationFrom: tx.generationFrom,
        generationTo: tx.generationTo,
        strategy: tx.strategy,
        phase: tx.phase,
        timestamp: DateTime.now().toUtc(),
        message: message ?? tx.message,
      ),
    );
  }
}
