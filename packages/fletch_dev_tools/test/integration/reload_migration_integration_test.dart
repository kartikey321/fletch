import 'dart:io';

import 'package:fletch_dev_tools/src/reload_engine/reload_engine.dart';
import 'package:test/test.dart';

import '../fixtures/migration_fixture_hooks.dart';

void main() {
  group('Reload migration integration', () {
    test('success path runs prepare then commit in fixture hooks', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('fletch_migration_it_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logFile = File('${tempDir.path}/migration.log');

      final hookA = RecordingMigrationHook(name: 'a', logFile: logFile);
      final hookB = RecordingMigrationHook(name: 'b', logFile: logFile);
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: true),
        hooks: [hookA, hookB],
      );

      final session = runner.createSession(_context());
      await session.prepare();
      await session.commit();

      final lines = await _readLines(logFile);
      expect(lines, equals(['prepare:a', 'prepare:b', 'commit:a', 'commit:b']));
    });

    test('commit failure triggers rollback in reverse hook order', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('fletch_migration_it_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logFile = File('${tempDir.path}/migration.log');

      final hookA = RecordingMigrationHook(name: 'a', logFile: logFile);
      final hookB = RecordingMigrationHook(
        name: 'b',
        logFile: logFile,
        failCommit: true,
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: true),
        hooks: [hookA, hookB],
      );

      final session = runner.createSession(_context());
      await session.prepare();
      await expectLater(
        session.commit(),
        throwsA(isA<ReloadMigrationException>()),
      );

      final lines = await _readLines(logFile);
      expect(lines[0], 'prepare:a');
      expect(lines[1], 'prepare:b');
      expect(lines[2], 'commit:a');
      expect(lines[3], 'commit:b');
      expect(lines[4], startsWith('rollback:b:'));
      expect(lines[5], startsWith('rollback:a:'));
    });

    test('prepare timeout rolls back already prepared hooks', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('fletch_migration_it_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logFile = File('${tempDir.path}/migration.log');

      final fast = RecordingMigrationHook(name: 'fast', logFile: logFile);
      final slow = RecordingMigrationHook(
        name: 'slow',
        logFile: logFile,
        prepareDelay: const Duration(milliseconds: 25),
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(
          enabled: true,
          prepareTimeout: Duration(milliseconds: 5),
        ),
        hooks: [fast, slow],
      );

      final session = runner.createSession(_context());
      await expectLater(
        session.prepare(),
        throwsA(isA<ReloadMigrationException>()),
      );

      final lines = await _readLines(logFile);
      expect(lines[0], 'prepare:fast');
      expect(lines[1], 'prepare:slow');
      expect(lines[2], startsWith('rollback:fast:'));
    });
  });
}

ReloadMigrationContext _context() {
  return ReloadMigrationContext(
    transactionId: 'tx-900001',
    generationFrom: const GenerationId('gen-000010'),
    generationTo: const GenerationId('gen-000011'),
    strategy: ReloadStrategy.containerShapeChange,
    changedPaths: const ['lib/src/container.dart'],
    invalidatedPaths: const ['lib/src/container.dart', 'lib/src/app.dart'],
    createdAt: DateTime.utc(2026, 3, 20),
  );
}

Future<List<String>> _readLines(File file) async {
  if (!await file.exists()) return const [];
  final content = await file.readAsString();
  return content
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}
