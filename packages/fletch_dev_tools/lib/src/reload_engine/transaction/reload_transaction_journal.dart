import 'dart:convert';
import 'dart:io';

import 'reload_transaction.dart';

/// Append-only storage abstraction for reload transactions.
abstract class ReloadTransactionJournal {
  Future<void> append(ReloadTransaction transaction);

  Future<List<ReloadTransaction>> readAll();
}

/// File-based JSONL transaction journal.
class FileReloadTransactionJournal implements ReloadTransactionJournal {
  final String filePath;

  Future<void> _pendingWrite = Future<void>.value();

  FileReloadTransactionJournal(this.filePath);

  @override
  Future<void> append(ReloadTransaction transaction) async {
    _pendingWrite = _pendingWrite.then((_) async {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(transaction.toJson())}\n',
        mode: FileMode.append,
      );
    });
    await _pendingWrite;
  }

  @override
  Future<List<ReloadTransaction>> readAll() async {
    final file = File(filePath);
    if (!await file.exists()) return const [];

    final lines = await file.readAsLines();
    final output = <ReloadTransaction>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final raw = jsonDecode(trimmed);
      if (raw is! Map) {
        throw FormatException('Invalid transaction journal line: $trimmed');
      }
      output.add(
        ReloadTransaction.fromJson(raw.cast<String, Object?>()),
      );
    }
    return output;
  }
}

/// In-memory journal implementation for tests.
class InMemoryReloadTransactionJournal implements ReloadTransactionJournal {
  final List<ReloadTransaction> _entries = [];

  @override
  Future<void> append(ReloadTransaction transaction) async {
    _entries.add(transaction);
  }

  @override
  Future<List<ReloadTransaction>> readAll() async {
    return List<ReloadTransaction>.from(_entries);
  }
}
