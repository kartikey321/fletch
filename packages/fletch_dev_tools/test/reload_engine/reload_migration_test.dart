import 'dart:async';

import 'package:fletch_dev_tools/src/reload_engine/reload_engine.dart';
import 'package:test/test.dart';

void main() {
  group('ReloadMigrationSession', () {
    ReloadMigrationContext context() {
      return ReloadMigrationContext(
        transactionId: 'tx-000001',
        generationFrom: const GenerationId('gen-000001'),
        generationTo: const GenerationId('gen-000002'),
        strategy: ReloadStrategy.containerShapeChange,
        changedPaths: const ['lib/src/container.dart'],
        invalidatedPaths: const ['lib/src/container.dart', 'lib/src/app.dart'],
        createdAt: DateTime.utc(2026, 3, 20),
      );
    }

    test('runs prepare then commit in declared hook order', () async {
      final calls = <String>[];
      final a = _Hook(
        name: 'a',
        onPrepare: () async => calls.add('a.prepare'),
        onCommit: () async => calls.add('a.commit'),
      );
      final b = _Hook(
        name: 'b',
        onPrepare: () async => calls.add('b.prepare'),
        onCommit: () async => calls.add('b.commit'),
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: true),
        hooks: [a, b],
      );

      final session = runner.createSession(context());
      await session.prepare();
      await session.commit();

      expect(
        calls,
        equals(['a.prepare', 'b.prepare', 'a.commit', 'b.commit']),
      );
      expect(session.didPrepare, isTrue);
      expect(session.didCommit, isTrue);
    });

    test('prepare failure rolls back already prepared hooks in reverse order',
        () async {
      final calls = <String>[];
      final a = _Hook(
        name: 'a',
        onPrepare: () async => calls.add('a.prepare'),
        onRollback: (reason) async => calls.add('a.rollback:$reason'),
      );
      final b = _Hook(
        name: 'b',
        onPrepare: () async {
          calls.add('b.prepare');
          throw StateError('b prepare failed');
        },
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: true),
        hooks: [a, b],
      );

      final session = runner.createSession(context());
      await expectLater(
        session.prepare(),
        throwsA(
          isA<ReloadMigrationException>().having(
            (e) => e.phase,
            'phase',
            ReloadMigrationPhase.prepare,
          ),
        ),
      );

      expect(calls[0], 'a.prepare');
      expect(calls[1], 'b.prepare');
      expect(calls[2], startsWith('a.rollback:prepare failed at hook b:'));
      expect(session.didRollback, isTrue);
    });

    test('commit failure rolls back prepared hooks in reverse order', () async {
      final calls = <String>[];
      final a = _Hook(
        name: 'a',
        onPrepare: () async => calls.add('a.prepare'),
        onCommit: () async => calls.add('a.commit'),
        onRollback: (reason) async => calls.add('a.rollback'),
      );
      final b = _Hook(
        name: 'b',
        onPrepare: () async => calls.add('b.prepare'),
        onCommit: () async {
          calls.add('b.commit');
          throw StateError('b commit failed');
        },
        onRollback: (reason) async => calls.add('b.rollback'),
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: true),
        hooks: [a, b],
      );

      final session = runner.createSession(context());
      await session.prepare();
      await expectLater(
        session.commit(),
        throwsA(
          isA<ReloadMigrationException>().having(
            (e) => e.phase,
            'phase',
            ReloadMigrationPhase.commit,
          ),
        ),
      );

      expect(
        calls,
        equals([
          'a.prepare',
          'b.prepare',
          'a.commit',
          'b.commit',
          'b.rollback',
          'a.rollback',
        ]),
      );
      expect(session.didRollback, isTrue);
    });

    test('prepare timeout throws migration exception', () async {
      final slow = _Hook(
        name: 'slow',
        onPrepare: () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(
          enabled: true,
          prepareTimeout: Duration(milliseconds: 5),
        ),
        hooks: [slow],
      );

      final session = runner.createSession(context());
      await expectLater(
        session.prepare(),
        throwsA(
          isA<ReloadMigrationException>().having(
            (e) => e.phase,
            'phase',
            ReloadMigrationPhase.prepare,
          ),
        ),
      );
    });

    test('disabled policy performs no hook operations', () async {
      final calls = <String>[];
      final hook = _Hook(
        name: 'noop',
        onPrepare: () async => calls.add('prepare'),
        onCommit: () async => calls.add('commit'),
        onRollback: (reason) async => calls.add('rollback'),
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: false),
        hooks: [hook],
      );

      final session = runner.createSession(context());
      await session.prepare();
      await session.commit();
      await session.rollback(reason: 'manual rollback');

      expect(calls, isEmpty);
    });

    test('explicit rollback is idempotent', () async {
      final calls = <String>[];
      final a = _Hook(
        name: 'a',
        onPrepare: () async => calls.add('a.prepare'),
        onRollback: (reason) async => calls.add('a.rollback'),
      );
      final b = _Hook(
        name: 'b',
        onPrepare: () async => calls.add('b.prepare'),
        onRollback: (reason) async => calls.add('b.rollback'),
      );
      final runner = ReloadMigrationRunner(
        policy: const ReloadMigrationPolicy(enabled: true),
        hooks: [a, b],
      );

      final session = runner.createSession(context());
      await session.prepare();
      await session.rollback(reason: 'manual rollback');
      await session.rollback(reason: 'manual rollback');

      expect(calls,
          equals(['a.prepare', 'b.prepare', 'b.rollback', 'a.rollback']));
    });
  });
}

class _Hook implements ReloadStateMigrationHook {
  @override
  final String name;
  final Future<void> Function()? _onPrepare;
  final Future<void> Function()? _onCommit;
  final Future<void> Function(String reason)? _onRollback;

  _Hook({
    required this.name,
    Future<void> Function()? onPrepare,
    Future<void> Function()? onCommit,
    Future<void> Function(String reason)? onRollback,
  })  : _onPrepare = onPrepare,
        _onCommit = onCommit,
        _onRollback = onRollback;

  @override
  Future<void> onPrepare(ReloadMigrationContext context) async {
    await _onPrepare?.call();
  }

  @override
  Future<void> onCommit(ReloadMigrationContext context) async {
    await _onCommit?.call();
  }

  @override
  Future<void> onRollback(
    ReloadMigrationContext context, {
    required String reason,
  }) async {
    await _onRollback?.call(reason);
  }
}
