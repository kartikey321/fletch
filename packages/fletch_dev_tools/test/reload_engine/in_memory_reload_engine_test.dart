import 'package:fletch_dev_tools/src/reload_engine/classifier/change_set.dart';
import 'package:fletch_dev_tools/src/reload_engine/runtime/reload_transaction_engine.dart';
import 'package:fletch_dev_tools/src/reload_engine/runtime/reload_event.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/generation_id.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_phase.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_strategy.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_transaction_journal.dart';
import 'package:test/test.dart';

void main() {
  group('ReloadTransactionEngine', () {
    test('start/stop toggles running state', () async {
      final engine = ReloadTransactionEngine();
      expect(engine.isRunning, isFalse);

      await engine.start();
      expect(engine.isRunning, isTrue);

      await engine.stop();
      expect(engine.isRunning, isFalse);
    });

    test('simulateHappyPath emits ordered phases and commits', () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      final events = <ReloadEvent>[];
      final sub = engine.events.listen(events.add);
      addTearDown(sub.cancel);

      final tx = await engine.simulateHappyPath(
        changeSet: ChangeSet(changedPaths: ['lib/api.dart']),
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.bodyOnlyHotSwap,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(tx.phase, ReloadPhase.committed);
      expect(events, isNotEmpty);
      expect(events.first.phase, ReloadPhase.detected);
      expect(events.last.phase, ReloadPhase.committed);
      expect(events.last.type, ReloadEventType.committed);
    });

    test('fails transaction explicitly from classifying phase', () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      var tx = await engine.createTransaction(
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.routeGraphChange,
      );
      tx = await engine.advanceTransaction(tx, ReloadPhase.classifying);

      final failed = await engine.failTransaction(
        tx,
        message: 'classifier failed',
      );
      expect(failed.phase, ReloadPhase.failed);
      expect(failed.message, 'classifier failed');
    });

    test('advanceTransaction is idempotent for duplicate phase requests',
        () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      final tx = await engine.createTransaction(
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.bodyOnlyHotSwap,
      );
      final classifying = await engine.advanceTransaction(
        tx,
        ReloadPhase.classifying,
      );
      final duplicate = await engine.advanceTransaction(
        classifying,
        ReloadPhase.classifying,
      );

      expect(duplicate.transactionId, classifying.transactionId);
      expect(duplicate.phase, ReloadPhase.classifying);
    });

    test('stale transaction instances still advance using latest known state',
        () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      final original = await engine.createTransaction(
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.bodyOnlyHotSwap,
      );
      await engine.advanceTransaction(original, ReloadPhase.classifying);

      // Use stale original object, engine should resolve current state.
      final compiled = await engine.advanceTransaction(
        original,
        ReloadPhase.compiling,
      );
      expect(compiled.phase, ReloadPhase.compiling);
    });

    test('recovers unfinished transactions from journal on startup', () async {
      final journal = InMemoryReloadTransactionJournal();
      final seed = ReloadTransactionEngine(journal: journal);
      await seed.start();
      var tx = await seed.createTransaction(
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.routeGraphChange,
      );
      tx = await seed.advanceTransaction(tx, ReloadPhase.classifying);
      expect(tx.phase.isTerminal, isFalse);
      await seed.stop();

      final recoveredEngine = ReloadTransactionEngine(journal: journal);
      final events = <ReloadEvent>[];
      final sub = recoveredEngine.events.listen(events.add);
      addTearDown(sub.cancel);
      await recoveredEngine.start();

      final entries = await journal.readAll();
      final last = entries.last;
      expect(last.phase, ReloadPhase.aborted);
      expect(
        last.message,
        contains('Recovered on startup'),
      );

      // No strict ordering guarantee for async stream dispatch on startup,
      // but recovered event should eventually be observable.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events.any((e) => e.type == ReloadEventType.aborted), isTrue);
      await recoveredEngine.stop();
    });

    test('transaction counter resumes after journal replay', () async {
      final journal = InMemoryReloadTransactionJournal();
      final seed = ReloadTransactionEngine(journal: journal);
      await seed.start();
      var tx = await seed.createTransaction(
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.restartRequired,
      );
      tx = await seed.advanceTransaction(tx, ReloadPhase.classifying);
      await seed.stop();

      final restored = ReloadTransactionEngine(journal: journal);
      await restored.start();
      final next = await restored.createTransaction(
        generationFrom: GenerationId('gen-0002'),
        generationTo: GenerationId('gen-0003'),
        strategy: ReloadStrategy.restartRequired,
      );

      final firstId = int.parse(tx.transactionId.substring(3));
      final nextId = int.parse(next.transactionId.substring(3));
      expect(nextId, greaterThan(firstId));
      await restored.stop();
    });

    test('submit creates a classifying transaction', () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      final tx = await engine.submit(
        ChangeSet(changedPaths: ['lib/a.dart', 'lib/b.dart']),
        strategy: ReloadStrategy.routeGraphChange,
      );
      expect(tx.phase, ReloadPhase.classifying);
      expect(tx.transactionId, startsWith('tx-'));
    });

    test('terminal transactions are pruned from active cache', () async {
      final engine = ReloadTransactionEngine();
      await engine.start();
      addTearDown(engine.stop);

      var tx = await engine.createTransaction(
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.bodyOnlyHotSwap,
      );
      expect(engine.activeTransactionCount, 1);

      tx = await engine.advanceTransaction(tx, ReloadPhase.classifying);
      tx = await engine.advanceTransaction(tx, ReloadPhase.compiling);
      tx = await engine.advanceTransaction(tx, ReloadPhase.staging);
      tx = await engine.advanceTransaction(tx, ReloadPhase.activating);
      tx = await engine.advanceTransaction(tx, ReloadPhase.retiring);
      tx = await engine.advanceTransaction(tx, ReloadPhase.committed);

      expect(tx.phase, ReloadPhase.committed);
      expect(engine.activeTransactionCount, 0);
    });
  });
}
