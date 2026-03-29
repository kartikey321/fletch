import 'dart:collection';
import 'dart:io';

import 'package:fletch_dev_tools/src/reload_engine/compiler/incremental_compiler_session.dart';
import 'package:test/test.dart';

void main() {
  group('IncrementalCompilerSession', () {
    test('recovers within one cycle when compile call throws', () async {
      final initialClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline ok'],
          ),
          StateError('daemon desync during compile'),
        ],
      );
      final recoveredClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline recovered'],
          ),
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['compile recovered'],
          ),
        ],
      );
      final factory = _FakeClientFactory([initialClient, recoveredClient]);

      final compiler = IncrementalCompiler(
        entryPoint: 'bin/main.dart',
        clientFactory: factory.call,
      );

      await compiler.start();
      final result = await compiler.compileInvalidated(['lib/src/a.dart']);
      await compiler.stop();

      expect(result.success, isTrue);
      expect(result.invalidatedFileCount, 1);
      expect(result.recoveredFromDesync, isTrue);
      expect(result.recoveryReason, contains('compile threw'));
      expect(factory.startCount, 2);
    });

    test('bounds diagnostics in normal mode and rejects on compile errors',
        () async {
      final client = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline ok'],
          ),
          IncrementalCompilerCompileOutput(
            errorCount: 2,
            compilerOutputLines: ['d1', 'd2', 'd3', 'd4', 'd5'],
          ),
        ],
      );
      final factory = _FakeClientFactory([client]);

      final compiler = IncrementalCompiler(
        entryPoint: 'bin/main.dart',
        maxDiagnostics: 3,
        verbose: false,
        clientFactory: factory.call,
      );

      await compiler.start();
      final result = await compiler.compileInvalidated(['lib/src/a.dart']);
      await compiler.stop();

      expect(result.success, isFalse);
      expect(result.diagnostics, hasLength(4));
      expect(result.diagnostics.last, contains('truncated'));
      expect(client.rejectCount, 1);
    });

    test('recovers when accept throws after successful compile', () async {
      final initialClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline ok'],
          ),
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['compile ok'],
          ),
        ],
        acceptActions: [
          null, // start baseline accept
          StateError('accept desync'),
        ],
      );
      final recoveredClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline recovered'],
          ),
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['compile recovered'],
          ),
        ],
      );
      final factory = _FakeClientFactory([initialClient, recoveredClient]);

      final compiler = IncrementalCompiler(
        entryPoint: 'bin/main.dart',
        clientFactory: factory.call,
      );

      await compiler.start();
      final result = await compiler.compileInvalidated(['lib/src/a.dart']);
      await compiler.stop();

      expect(result.success, isTrue);
      expect(result.recoveredFromDesync, isTrue);
      expect(result.recoveryReason, contains('accept threw'));
      expect(factory.startCount, 2);
    });

    test('start throws when baseline compile has errors', () async {
      final client = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 1,
            compilerOutputLines: ['baseline error'],
          ),
        ],
      );
      final factory = _FakeClientFactory([client]);

      final compiler = IncrementalCompiler(
        entryPoint: 'bin/main.dart',
        clientFactory: factory.call,
      );

      await expectLater(compiler.start(), throwsA(isA<StateError>()));
      expect(client.rejectCount, 1);
      await compiler.stop();
    });

    test('does not recover when max recovery attempts is zero', () async {
      final initialClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline ok'],
          ),
          StateError('daemon desync during compile'),
        ],
      );
      final unusedClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline recovered'],
          ),
        ],
      );
      final factory = _FakeClientFactory([initialClient, unusedClient]);

      final compiler = IncrementalCompiler(
        entryPoint: 'bin/main.dart',
        maxRecoveryAttempts: 0,
        clientFactory: factory.call,
      );

      await compiler.start();
      final result = await compiler.compileInvalidated(['lib/src/a.dart']);
      await compiler.stop();

      expect(result.success, isFalse);
      expect(result.recoveredFromDesync, isFalse);
      expect(result.recoveryReason, contains('compile threw'));
      expect(factory.startCount, 1);
    });

    test('applies linear recovery backoff across retries', () async {
      final slept = <Duration>[];
      final initialClient = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline ok'],
          ),
          StateError('compile desync 1'),
        ],
      );
      final recovered1 = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline recovered 1'],
          ),
          StateError('compile desync 2'),
        ],
      );
      final recovered2 = _FakeCompilerClient(
        compileActions: [
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['baseline recovered 2'],
          ),
          IncrementalCompilerCompileOutput(
            errorCount: 0,
            compilerOutputLines: ['compile recovered'],
          ),
        ],
      );
      final factory =
          _FakeClientFactory([initialClient, recovered1, recovered2]);

      final compiler = IncrementalCompiler(
        entryPoint: 'bin/main.dart',
        maxRecoveryAttempts: 2,
        recoveryBackoff: const Duration(milliseconds: 40),
        sleep: (duration) async {
          slept.add(duration);
        },
        clientFactory: factory.call,
      );

      await compiler.start();
      final result = await compiler.compileInvalidated(['lib/src/a.dart']);
      await compiler.stop();

      expect(result.success, isTrue);
      expect(result.recoveredFromDesync, isTrue);
      expect(
          slept,
          equals(
              const [Duration(milliseconds: 40), Duration(milliseconds: 80)]));
      expect(factory.startCount, 3);
    });

    test('validates constructor knobs', () {
      expect(
        () => IncrementalCompiler(
          entryPoint: 'bin/main.dart',
          maxDiagnostics: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => IncrementalCompiler(
          entryPoint: 'bin/main.dart',
          maxRecoveryAttempts: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => IncrementalCompiler(
          entryPoint: 'bin/main.dart',
          recoveryBackoff: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });
  });
}

class _FakeClientFactory {
  final Queue<_FakeCompilerClient> _clients;
  int startCount = 0;

  _FakeClientFactory(List<_FakeCompilerClient> clients)
      : _clients = Queue.of(clients);

  Future<IncrementalCompilerClient> call(
    IncrementalCompilerStartOptions options,
  ) async {
    startCount++;
    if (_clients.isEmpty) {
      throw StateError('No fake compiler client available');
    }
    return _clients.removeFirst();
  }
}

class _FakeCompilerClient implements IncrementalCompilerClient {
  final Queue<Object?> _compileActions;
  final Queue<Object?> _acceptActions;
  final Queue<Object?> _rejectActions;

  int compileCount = 0;
  int acceptCount = 0;
  int rejectCount = 0;
  int shutdownCount = 0;
  int killCount = 0;

  _FakeCompilerClient({
    required List<Object?> compileActions,
    List<Object?> acceptActions = const [],
    List<Object?> rejectActions = const [],
  })  : _compileActions = Queue.of(compileActions),
        _acceptActions = Queue.of(acceptActions),
        _rejectActions = Queue.of(rejectActions);

  @override
  Future<IncrementalCompilerCompileOutput> compile(
      [List<Uri>? invalidated]) async {
    compileCount++;
    if (_compileActions.isEmpty) {
      throw StateError('No compile action configured');
    }
    final action = _compileActions.removeFirst();
    if (action is Exception) throw action;
    if (action is Error) throw action;
    return action as IncrementalCompilerCompileOutput;
  }

  @override
  void accept() {
    acceptCount++;
    if (_acceptActions.isEmpty) return;
    final action = _acceptActions.removeFirst();
    if (action is Exception) throw action;
    if (action is Error) throw action;
  }

  @override
  Future<void> reject() async {
    rejectCount++;
    if (_rejectActions.isEmpty) return;
    final action = _rejectActions.removeFirst();
    if (action is Exception) throw action;
    if (action is Error) throw action;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
  }

  @override
  void kill({ProcessSignal processSignal = ProcessSignal.sigkill}) {
    killCount++;
  }
}
