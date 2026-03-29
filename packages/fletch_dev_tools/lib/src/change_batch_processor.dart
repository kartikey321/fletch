import 'package:watcher/watcher.dart';

import 'change_batch_queue.dart';

typedef ChangeBatchHandler = Future<void> Function(List<WatchEvent> batch);

/// Serializes batch handling while still accepting new events during processing.
///
/// Enqueued events are coalesced by path and drained until quiescent, which
/// prevents drop-on-busy behavior during save storms.
class ChangeBatchProcessor {
  final ChangeBatchQueue _queue;
  final ChangeBatchHandler _handler;

  bool _draining = false;

  ChangeBatchProcessor({
    ChangeBatchQueue? queue,
    required ChangeBatchHandler handler,
  })  : _queue = queue ?? ChangeBatchQueue(),
        _handler = handler;

  bool get isDraining => _draining;

  int get pendingDepth => _queue.depth;

  Future<void> enqueue(List<WatchEvent> events) async {
    _queue.enqueueAll(events);
    if (_draining) return;
    _draining = true;
    try {
      while (!_queue.isEmpty) {
        final nextBatch = _queue.drain();
        if (nextBatch.isEmpty) continue;
        await _handler(nextBatch);
      }
    } finally {
      _draining = false;
    }
  }
}
