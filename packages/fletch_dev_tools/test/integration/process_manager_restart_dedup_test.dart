import 'dart:async';
import 'dart:io';

import 'package:fletch_dev_tools/src/process_manager.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessManager restart de-duplication', () {
    test('ignores overlapping restart calls and performs only one lifecycle',
        () async {
      final workspace = await _createFixtureWorkspace();
      final port = await _reservePort();
      final phases = <String>[];

      final manager = ProcessManager(
        entryPoint: '${workspace.path}/bin/server.dart',
        port: port,
        onRestartLifecycle: phases.add,
      );

      try {
        await manager.start();

        // Trigger two restarts concurrently; the second should be dedup-skipped.
        await Future.wait<void>([
          manager.restart(),
          manager.restart(),
        ]);

        expect(
          phases.where((p) => p == 'begin').length,
          1,
          reason: 'Only one restart cycle should begin.',
        );
        expect(
          phases.where((p) => p == 'dedup-skipped').length,
          1,
          reason: 'One overlapping call should be skipped.',
        );
        expect(
          phases.where((p) => p == 'done').length,
          1,
          reason: 'Only one restart cycle should complete.',
        );
        expect(
          phases.last,
          'idle',
          reason: 'Manager should return to idle after restart.',
        );
      } finally {
        await manager.stop();
        if (workspace.existsSync()) {
          await workspace.delete(recursive: true);
        }
      }
    });
  });
}

Future<Directory> _createFixtureWorkspace() async {
  final root = _resolvePackageRoot();
  final base = Directory('${root.path}/test/process_manager_tmp');
  await base.create(recursive: true);
  final dir = await base.createTemp('fletch_pm_restart_');
  await Directory('${dir.path}/bin').create(recursive: true);

  final entryPoint = File('${dir.path}/bin/server.dart');
  await entryPoint.writeAsString('''
import 'dart:io';

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

  // Keep process alive until killed by ProcessManager.stop().
  await for (final request in server) {
    request.response
      ..statusCode = HttpStatus.ok
      ..write('ok');
    await request.response.close();
  }
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

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
