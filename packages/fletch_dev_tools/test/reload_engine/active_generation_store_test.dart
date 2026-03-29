import 'package:fletch_dev_tools/src/reload_engine/runtime/active_generation_store.dart';
import 'package:fletch_dev_tools/src/reload_engine/runtime/generation_handle.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/generation_id.dart';
import 'package:test/test.dart';

void main() {
  group('ActiveGenerationStore', () {
    test('initializes and activates generations', () {
      final store = ActiveGenerationStore();
      final first = GenerationHandle(
        id: const GenerationId('gen-0001'),
        createdAt: DateTime.utc(2026, 3, 20),
      );
      final active = store.initialize(first);
      expect(store.hasActive, isTrue);
      expect(active.activatedAt, isNotNull);
      expect(store.active?.id.value, 'gen-0001');

      final second = GenerationHandle(
        id: const GenerationId('gen-0002'),
        createdAt: DateTime.utc(2026, 3, 20, 0, 0, 1),
      );
      store.activate(second);
      expect(store.active?.id.value, 'gen-0002');
    });

    test('tracks in-flight leases by generation', () {
      final store = ActiveGenerationStore();
      store.initialize(
        GenerationHandle(
          id: const GenerationId('gen-0001'),
          createdAt: DateTime.utc(2026, 3, 20),
        ),
      );

      final lease1 = store.beginRequest();
      final lease2 = store.beginRequest();
      expect(lease1.generationId, 'gen-0001');
      expect(store.inFlightFor('gen-0001'), 2);

      lease1.release();
      expect(store.inFlightFor('gen-0001'), 1);

      lease1.release(); // idempotent release
      expect(store.inFlightFor('gen-0001'), 1);

      lease2.release();
      expect(store.inFlightFor('gen-0001'), 0);
    });
  });
}
