import 'dart:async';
import 'dart:io';

import 'package:fletch_dev_tools/src/dev_server.dart';
import 'package:fletch_dev_tools/src/reload_engine/reload_engine.dart';
import 'package:test/test.dart';

import '../fixtures/migration_fixture_hooks.dart';

void main() {
  group('FletchDevServer migration e2e', () {
    test('container-shape edit runs migration prepare and commit hooks',
        () async {
      final workspace = await _createFixtureWorkspace();
      final port = await _reservePort();
      final migrationLog = File('${workspace.path}/migration.log');
      final hookA = RecordingMigrationHook(name: 'a', logFile: migrationLog);
      final hookB = RecordingMigrationHook(name: 'b', logFile: migrationLog);

      final server = FletchDevServer(
        entryPoint: '${workspace.path}/bin/server.dart',
        port: port,
        watchDirectories: ['${workspace.path}/lib'],
        migrationPolicy: const ReloadMigrationPolicy(enabled: true),
        migrationHooks: [hookA, hookB],
      );

      addTearDown(() async {
        await server.stop();
        await workspace.delete(recursive: true);
      });

      await server.start();
      await Future<void>.delayed(const Duration(seconds: 1));
      await _mutateContainerFile(workspace, from: 'return 1;', to: 'return 2;');

      await _waitForLogLines(
        migrationLog,
        (lines) =>
            lines.length >= 4 &&
            lines[0] == 'prepare:a' &&
            lines[1] == 'prepare:b' &&
            lines[2] == 'commit:a' &&
            lines[3] == 'commit:b',
        description: 'prepare/commit sequence',
      );
    });

    test('migration commit failure triggers rollback and aborts cycle',
        () async {
      final workspace = await _createFixtureWorkspace();
      final port = await _reservePort();
      final migrationLog = File('${workspace.path}/migration.log');
      final hookA = RecordingMigrationHook(name: 'a', logFile: migrationLog);
      final hookB = RecordingMigrationHook(
        name: 'b',
        logFile: migrationLog,
        failCommit: true,
      );

      final server = FletchDevServer(
        entryPoint: '${workspace.path}/bin/server.dart',
        port: port,
        watchDirectories: ['${workspace.path}/lib'],
        migrationPolicy: const ReloadMigrationPolicy(enabled: true),
        migrationHooks: [hookA, hookB],
      );

      addTearDown(() async {
        await server.stop();
        await workspace.delete(recursive: true);
      });

      await server.start();
      await Future<void>.delayed(const Duration(seconds: 1));
      await _mutateContainerFile(workspace, from: 'return 1;', to: 'return 3;');

      await _waitForLogLines(
        migrationLog,
        (lines) =>
            lines.length >= 6 &&
            lines[0] == 'prepare:a' &&
            lines[1] == 'prepare:b' &&
            lines[2] == 'commit:a' &&
            lines[3] == 'commit:b' &&
            lines[4].startsWith('rollback:b:') &&
            lines[5].startsWith('rollback:a:'),
        description: 'rollback order for commit failure',
      );
    });
  });
}

Future<Directory> _createFixtureWorkspace() async {
  final root = _resolvePackageRoot();
  final base = Directory('${root.path}/test/migration_e2e_tmp');
  await base.create(recursive: true);
  final dir = await base.createTemp('fletch_migration_e2e_');
  await Directory('${dir.path}/bin').create(recursive: true);
  await Directory('${dir.path}/lib').create(recursive: true);

  final entryPoint = File('${dir.path}/bin/server.dart');
  await entryPoint.writeAsString('''
import 'dart:io';
import 'package:fletch/fletch.dart';
import 'package:fletch_dev_tools/fletch_dev_tools.dart';
import '../lib/migration_container.dart';

void _register(Fletch app) {
  app.get('/ping', (req, res) => res.text('ok'));
  app.get('/version', (req, res) => res.text('v\${containerMigrationVersion()}'));
}

Future<void> main() async {
  final app = Fletch(
    secureCookies: false,
    requestTimeout: const Duration(seconds: 6),
    shutdownTimeout: const Duration(seconds: 3),
  );
  configureDevHotReload(
    app,
    registerRoutes: () => _register(app),
    enabled: true,
  );
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 0;
  await app.listen(port == 0 ? 0 : port, address: InternetAddress.loopbackIPv4);
}
''');

  final migrationFile = File('${dir.path}/lib/migration_container.dart');
  await migrationFile.writeAsString('''
int containerMigrationVersion() {
  const marker = 'register';
  return 1;
}
''');

  return dir;
}

Directory _resolvePackageRoot() {
  final direct = Directory.current;
  if (File('${direct.path}/pubspec.yaml').existsSync() &&
      File('${direct.path}/bin/fletch.dart').existsSync()) {
    return direct;
  }

  final nested = Directory('${direct.path}/packages/fletch_dev_tools');
  if (File('${nested.path}/pubspec.yaml').existsSync() &&
      File('${nested.path}/bin/fletch.dart').existsSync()) {
    return nested;
  }

  throw StateError(
    'Could not resolve fletch_dev_tools package root from ${Directory.current.path}',
  );
}

Future<void> _mutateContainerFile(
  Directory workspace, {
  required String from,
  required String to,
}) async {
  final file = File('${workspace.path}/lib/migration_container.dart');
  final original = await file.readAsString();
  final updated = original.replaceFirst(from, to);
  if (original == updated) {
    throw StateError('Could not mutate migration container fixture file');
  }
  await file.writeAsString(
      '$updated\n// mutation-${DateTime.now().microsecondsSinceEpoch}\n');
}

Future<void> _waitForLogLines(
  File logFile,
  bool Function(List<String> lines) matches, {
  required String description,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final lines = await _readLines(logFile);
    if (matches(lines)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  final lines = await _readLines(logFile);
  throw StateError(
    'Timed out waiting for migration lines ($description). Got: $lines',
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

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
