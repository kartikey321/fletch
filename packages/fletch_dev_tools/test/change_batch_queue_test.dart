import 'package:fletch_dev_tools/src/change_batch_queue.dart';
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

void main() {
  group('ChangeBatchQueue', () {
    test('deduplicates by path and keeps latest event', () {
      final queue = ChangeBatchQueue();

      queue.enqueueAll([
        WatchEvent(ChangeType.MODIFY, 'lib/a.dart'),
        WatchEvent(ChangeType.REMOVE, 'lib/a.dart'),
      ]);

      expect(queue.depth, 1);
      final drained = queue.drain();
      expect(drained, hasLength(1));
      expect(drained.first.path, 'lib/a.dart');
      expect(drained.first.type, ChangeType.REMOVE);
    });

    test('drains in sorted path order', () {
      final queue = ChangeBatchQueue();

      queue.enqueueAll([
        WatchEvent(ChangeType.MODIFY, 'lib/z.dart'),
        WatchEvent(ChangeType.MODIFY, 'lib/a.dart'),
        WatchEvent(ChangeType.MODIFY, 'lib/m.dart'),
      ]);

      final drained = queue.drain();
      expect(
        drained.map((event) => event.path).toList(growable: false),
        ['lib/a.dart', 'lib/m.dart', 'lib/z.dart'],
      );
      expect(queue.isEmpty, isTrue);
    });
  });
}
