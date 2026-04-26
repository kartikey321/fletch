import 'dart:async';

import 'package:watcher/watcher.dart';

import 'change_batch_queue.dart';

typedef ChangeBatchHandler = Future<void> Function(List<WatchEvent> batch);

/// Serializes batch handling while still accepting new events during processing.
///
/// Enqueued events are coalesced by path and drained until quiescent, which
/// prevents drop-on-busy behavior during save storms.
///
/// This processor is close-aware:
/// - [enqueue] is ignored after [close] (returns `false`)
/// - active draining is awaited by [close]
/// - no new batches are started once closed
class ChangeBatchProcessor {
  final ChangeBatchQueue _queue;
  final ChangeBatchHandler _handler;

  bool _draining = false;
  bool _closed = false;
  Completer<void>? _drainCompleter;

  ChangeBatchProcessor({
    ChangeBatchQueue? queue,
    required ChangeBatchHandler handler,
  })  : _queue = queue ?? ChangeBatchQueue(),
        _handler = handler;

  bool get isDraining => _draining;

  bool get isClosed => _closed;

  int get pendingDepth => _queue.depth;

  /// Enqueue a batch of file events.
  ///
  /// Returns `true` when accepted, `false` when the processor has already been
  /// closed and the batch is intentionally dropped.
  Future<bool> enqueue(List<WatchEvent> events) async {
    if (_closed) return false;

    _queue.enqueueAll(events);
    if (_draining) return true;

    _draining = true;
    _drainCompleter = Completer<void>();

    try {
      while (!_queue.isEmpty) {
        if (_closed) break;
        final nextBatch = _queue.drain();
        if (nextBatch.isEmpty) continue;
        await _handler(nextBatch);
      }
      return true;
    } finally {
      _draining = false;
      _drainCompleter?.complete();
      _drainCompleter = null;
    }
  }

  /// Prevents any further enqueue operations and waits for an in-flight drain.
  Future<void> close() async {
    if (_closed) {
      final drain = _drainCompleter;
      if (drain != null) await drain.future;
      return;
    }

    _closed = true;
    final drain = _drainCompleter;
    if (drain != null) {
      await drain.future;
    }

    // Drop any queued-but-not-processed events after shutdown.
    if (!_queue.isEmpty) {
      _queue.drain();
    }
  }
}
