import 'package:fletch_dev_tools/src/reload_engine/transaction/generation_id.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_phase.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_strategy.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_transaction.dart';
import 'package:test/test.dart';

void main() {
  group('ReloadTransaction transitions', () {
    test('supports valid happy-path transition sequence', () {
      var tx = ReloadTransaction.detected(
        transactionId: 'tx-000001',
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.bodyOnlyHotSwap,
        now: DateTime.utc(2026, 3, 19, 0, 0, 0),
      );

      tx = tx.transitionTo(ReloadPhase.classifying);
      tx = tx.transitionTo(ReloadPhase.compiling);
      tx = tx.transitionTo(ReloadPhase.staging);
      tx = tx.transitionTo(ReloadPhase.activating);
      tx = tx.transitionTo(ReloadPhase.retiring);
      tx = tx.transitionTo(ReloadPhase.committed);

      expect(tx.phase, ReloadPhase.committed);
      expect(tx.phase.isTerminal, isTrue);
    });

    test('rejects invalid transition jump', () {
      final tx = ReloadTransaction.detected(
        transactionId: 'tx-000002',
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.routeGraphChange,
      );

      expect(
        () => tx.transitionTo(ReloadPhase.staging),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects transitions from terminal phase', () {
      final committed = ReloadTransaction.detected(
        transactionId: 'tx-000003',
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.restartRequired,
      )
          .transitionTo(ReloadPhase.classifying)
          .transitionTo(ReloadPhase.compiling)
          .transitionTo(ReloadPhase.staging)
          .transitionTo(ReloadPhase.activating)
          .transitionTo(ReloadPhase.retiring)
          .transitionTo(ReloadPhase.committed);

      expect(
        () => committed.transitionTo(ReloadPhase.failed),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('ReloadTransaction serialization', () {
    test('round-trips json payload', () {
      final original = ReloadTransaction.detected(
        transactionId: 'tx-000010',
        generationFrom: GenerationId('gen-0007'),
        generationTo: GenerationId('gen-0008'),
        strategy: ReloadStrategy.containerShapeChange,
        now: DateTime.utc(2026, 3, 19, 10, 30, 0),
      ).transitionTo(
        ReloadPhase.classifying,
        now: DateTime.utc(2026, 3, 19, 10, 30, 2),
      );

      final parsed = ReloadTransaction.fromJson(original.toJson());

      expect(parsed.transactionId, original.transactionId);
      expect(parsed.generationFrom, original.generationFrom);
      expect(parsed.generationTo, original.generationTo);
      expect(parsed.strategy, original.strategy);
      expect(parsed.phase, original.phase);
      expect(parsed.createdAt, original.createdAt);
      expect(parsed.updatedAt, original.updatedAt);
    });
  });
}
