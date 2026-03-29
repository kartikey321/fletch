import 'dart:async';

import 'package:fletch_dev_tools/src/change_batch_processor.dart';
import 'package:fletch_dev_tools/src/change_batch_queue.dart';
import 'package:fletch_dev_tools/src/reload_engine/classifier/change_set.dart';
import 'package:fletch_dev_tools/src/reload_engine/runtime/reload_transaction_engine.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/generation_id.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_strategy.dart';
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

void main() {
  group('Phase 5 hardening harness', () {
    test('body-only benchmark meets p50/p95 transaction envelope', () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      final samplesMs = <int>[];
      const runs = 120;
      for (var i = 0; i < runs; i++) {
        final from =
            GenerationId('gen-${(1000 + i).toString().padLeft(6, '0')}');
        final to = GenerationId('gen-${(1001 + i).toString().padLeft(6, '0')}');
        final sw = Stopwatch()..start();
        await engine.simulateHappyPath(
          changeSet: ChangeSet(changedPaths: const ['lib/bench_target.dart']),
          generationFrom: from,
          generationTo: to,
          strategy: ReloadStrategy.bodyOnlyHotSwap,
        );
        sw.stop();
        samplesMs.add(sw.elapsedMilliseconds);
      }

      final p50 = _percentile(samplesMs, 50);
      final p95 = _percentile(samplesMs, 95);

      expect(p50, lessThan(150));
      expect(p95, lessThan(300));
    });

    test('save-storm queue drains without silent drops', () async {
      final seen = <String>{};
      final processor = ChangeBatchProcessor(
        queue: ChangeBatchQueue(),
        handler: (batch) async {
          for (final event in batch) {
            seen.add(event.path);
          }
        },
      );

      final expected = <String>{};
      final enqueues = <Future<void>>[];
      for (var burst = 0; burst < 25; burst++) {
        final events = <WatchEvent>[];
        for (var i = 0; i < 200; i++) {
          final path = 'lib/file_${i % 80}.dart';
          expected.add(path);
          events.add(WatchEvent(ChangeType.MODIFY, path));
        }
        enqueues.add(processor.enqueue(events));
      }

      await Future.wait(enqueues);

      expect(processor.pendingDepth, 0);
      expect(seen, expected);
      expect(seen.length, 80);
    });
  });
}

int _percentile(List<int> values, int percentile) {
  if (values.isEmpty) {
    throw ArgumentError('Cannot calculate percentile for empty list');
  }
  final sorted = [...values]..sort();
  final rank = (percentile / 100) * (sorted.length - 1);
  final index = rank.round().clamp(0, sorted.length - 1);
  return sorted[index];
}
