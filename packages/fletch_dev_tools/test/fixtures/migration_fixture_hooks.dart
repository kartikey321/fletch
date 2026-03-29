import 'dart:async';
import 'dart:io';

import 'package:fletch_dev_tools/src/reload_engine/reload_engine.dart';

/// File-backed migration hook used by integration tests.
class RecordingMigrationHook implements ReloadStateMigrationHook {
  @override
  final String name;
  final File logFile;
  final Duration prepareDelay;
  final Duration commitDelay;
  final Duration rollbackDelay;
  final bool failPrepare;
  final bool failCommit;

  RecordingMigrationHook({
    required this.name,
    required this.logFile,
    this.prepareDelay = Duration.zero,
    this.commitDelay = Duration.zero,
    this.rollbackDelay = Duration.zero,
    this.failPrepare = false,
    this.failCommit = false,
  });

  @override
  Future<void> onPrepare(ReloadMigrationContext context) async {
    await _append('prepare:$name');
    if (prepareDelay > Duration.zero) {
      await Future<void>.delayed(prepareDelay);
    }
    if (failPrepare) {
      throw StateError('prepare failed in $name');
    }
  }

  @override
  Future<void> onCommit(ReloadMigrationContext context) async {
    await _append('commit:$name');
    if (commitDelay > Duration.zero) {
      await Future<void>.delayed(commitDelay);
    }
    if (failCommit) {
      throw StateError('commit failed in $name');
    }
  }

  @override
  Future<void> onRollback(
    ReloadMigrationContext context, {
    required String reason,
  }) async {
    await _append('rollback:$name:$reason');
    if (rollbackDelay > Duration.zero) {
      await Future<void>.delayed(rollbackDelay);
    }
  }

  Future<void> _append(String line) async {
    await logFile.writeAsString('$line\n', mode: FileMode.append);
  }
}
