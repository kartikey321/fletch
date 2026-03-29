import 'dart:async';

import 'package:fletch_dev_tools/src/change_batch_processor.dart';
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

void main() {
  group('ChangeBatchProcessor integration', () {
    test('drains events that arrive while a batch is in-flight', () async {
      final handledPaths = <String>{};
      late final ChangeBatchProcessor processor;

      processor = ChangeBatchProcessor(
        handler: (batch) async {
          for (final event in batch) {
            handledPaths.add(event.path);
          }
          if (handledPaths.length == 1) {
            unawaited(
              processor.enqueue([
                WatchEvent(ChangeType.MODIFY, 'lib/b.dart'),
                WatchEvent(ChangeType.MODIFY, 'lib/c.dart'),
              ]),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
      );

      await processor.enqueue([
        WatchEvent(ChangeType.MODIFY, 'lib/a.dart'),
      ]);

      expect(
        handledPaths,
        containsAll(<String>['lib/a.dart', 'lib/b.dart', 'lib/c.dart']),
      );
    });

    test('save storm preserves all unique paths after coalescing', () async {
      final handledPaths = <String>{};
      final processor = ChangeBatchProcessor(
        handler: (batch) async {
          for (final event in batch) {
            handledPaths.add(event.path);
          }
          await Future<void>.delayed(const Duration(milliseconds: 8));
        },
      );

      final futures = <Future<void>>[];
      for (var i = 0; i < 120; i++) {
        futures.add(
          processor.enqueue([
            WatchEvent(ChangeType.MODIFY, 'lib/file${i % 6}.dart'),
          ]),
        );
      }
      await Future.wait(futures);

      expect(
        handledPaths,
        containsAll(List<String>.generate(6, (i) => 'lib/file$i.dart')),
      );
      expect(processor.pendingDepth, 0);
      expect(processor.isDraining, isFalse);
    });
  });
}
