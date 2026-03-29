import 'dart:io';

import 'package:fletch_dev_tools/src/reload_engine/transaction/generation_id.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_phase.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_strategy.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_transaction.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_transaction_journal.dart';
import 'package:test/test.dart';

void main() {
  group('FileReloadTransactionJournal', () {
    late Directory tempDir;
    late String journalPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fletch_journal_test_');
      journalPath = '${tempDir.path}/reload_transactions.jsonl';
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('appends and reads transactions in order', () async {
      final journal = FileReloadTransactionJournal(journalPath);

      final tx1 = ReloadTransaction.detected(
        transactionId: 'tx-000001',
        generationFrom: GenerationId('gen-0001'),
        generationTo: GenerationId('gen-0002'),
        strategy: ReloadStrategy.bodyOnlyHotSwap,
        now: DateTime.utc(2026, 3, 19, 1),
      );
      final tx2 = tx1.transitionTo(
        ReloadPhase.classifying,
        now: DateTime.utc(2026, 3, 19, 1, 0, 1),
      );

      await journal.append(tx1);
      await journal.append(tx2);

      final all = await journal.readAll();
      expect(all.length, 2);
      expect(all.first.phase, ReloadPhase.detected);
      expect(all.last.phase, ReloadPhase.classifying);
      expect(all.last.transactionId, 'tx-000001');
    });
  });
}
