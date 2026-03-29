import 'package:fletch_dev_tools/src/reload_engine/runtime/active_generation_store.dart';
import 'package:fletch_dev_tools/src/reload_engine/runtime/generation_handle.dart';
import 'package:fletch_dev_tools/src/reload_engine/runtime/generation_retire_manager.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/generation_id.dart';
import 'package:test/test.dart';

void main() {
  group('GenerationRetireManager', () {
    test('retires immediately when no inflight requests', () async {
      final store = ActiveGenerationStore();
      store.initialize(
        GenerationHandle(
          id: const GenerationId('gen-0001'),
          createdAt: DateTime.utc(2026, 3, 20),
        ),
      );

      final manager = GenerationRetireManager(store);
      final result = await manager.retire('gen-0001');

      expect(result.forced, isFalse);
      expect(result.remainingInFlight, 0);
      expect(store.isRetiring('gen-0001'), isFalse);
    });

    test('forces retire when timeout elapses with inflight requests', () async {
      final store = ActiveGenerationStore();
      store.initialize(
        GenerationHandle(
          id: const GenerationId('gen-0001'),
          createdAt: DateTime.utc(2026, 3, 20),
        ),
      );
      final lease = store.beginRequest();

      final manager = GenerationRetireManager(store);
      final result = await manager.retire(
        'gen-0001',
        timeout: const Duration(milliseconds: 15),
        pollInterval: const Duration(milliseconds: 5),
      );

      expect(result.forced, isTrue);
      expect(result.remainingInFlight, greaterThan(0));
      expect(store.isRetiring('gen-0001'), isFalse);

      lease.release();
    });
  });
}
