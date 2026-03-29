import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fletch_dev_tools/src/hot_reloader.dart';
import 'package:test/test.dart';

void main() {
  group('Runtime generation bridge integration', () {
    test('retire reflects real in-flight requests through VM extensions',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('fletch_runtime_bridge_');
      final serviceInfoFile = File('${tempDir.path}/vm_service.json');
      final port = await _reservePort();

      final process = await Process.start(
        'dart',
        [
          '--enable-vm-service=0',
          '--write-service-info=${serviceInfoFile.path}',
          'test/fixtures/runtime_bridge_app.dart',
        ],
        workingDirectory: _resolvePackageRoot().path,
        environment: {
          'PORT': '$port',
        },
      );

      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      });

      final vmServiceUri = await _waitForServiceUri(serviceInfoFile);
      await _waitForPing(port);

      final reloader = HotReloader();
      addTearDown(reloader.disconnect);
      final connected = await reloader.connect(serviceUri: vmServiceUri);
      expect(connected, isTrue);

      final activateGen1 = await reloader.activateGeneration('gen-000001');
      expect(activateGen1.available, isTrue);
      expect(activateGen1.success, isTrue);

      final slowResponseFuture = _get(port, '/slow');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final activateGen2 = await reloader.activateGeneration('gen-000002');
      expect(activateGen2.available, isTrue);
      expect(activateGen2.success, isTrue);

      final forcedRetire = await reloader.retireGeneration(
        'gen-000001',
        timeout: const Duration(milliseconds: 120),
      );
      expect(forcedRetire.available, isTrue);
      expect(forcedRetire.success, isTrue);
      expect(forcedRetire.forced, isTrue);

      final release = await _post(port, '/release');
      expect(release.statusCode, HttpStatus.ok);

      final slow = await slowResponseFuture.timeout(const Duration(seconds: 2));
      expect(slow.statusCode, HttpStatus.ok);
      expect(slow.body, contains('slow-done'));

      final drainedRetire = await reloader.retireGeneration(
        'gen-000002',
        timeout: const Duration(milliseconds: 400),
      );
      expect(drainedRetire.available, isTrue);
      expect(drainedRetire.success, isTrue);
      expect(drainedRetire.forced, isFalse);
    });
  });
}

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<Uri> _waitForServiceUri(
  File serviceInfoFile, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      if (!await serviceInfoFile.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        continue;
      }
      final raw = await serviceInfoFile.readAsString();
      if (raw.trim().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        continue;
      }
      final decoded = jsonDecode(raw);
      final uri = _extractUri(decoded);
      if (uri != null) return uri;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  throw TimeoutException('Timed out waiting for VM service URI', timeout);
}

Uri? _extractUri(dynamic data) {
  if (data is String) {
    return _tryParseUri(data);
  }
  if (data is Map) {
    for (final entry in data.entries) {
      if (entry.key.toString().toLowerCase().contains('uri')) {
        final parsed = _tryParseUri(entry.value?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      final nested = _extractUri(entry.value);
      if (nested != null) return nested;
    }
  }
  if (data is Iterable) {
    for (final item in data) {
      final nested = _extractUri(item);
      if (nested != null) return nested;
    }
  }
  return null;
}

Uri? _tryParseUri(String raw) {
  if (raw.isEmpty) return null;
  try {
    return Uri.parse(raw);
  } catch (_) {
    return null;
  }
}

Future<void> _waitForPing(
  int port, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final ping = await _get(port, '/ping');
      if (ping.statusCode == HttpStatus.ok) return;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  throw TimeoutException('Timed out waiting for HTTP /ping readiness', timeout);
}

Future<_HttpResult> _get(int port, String path) => _request('GET', port, path);

Future<_HttpResult> _post(int port, String path) =>
    _request('POST', port, path);

Future<_HttpResult> _request(String method, int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return _HttpResult(
      statusCode: response.statusCode,
      body: body,
    );
  } finally {
    client.close(force: true);
  }
}

class _HttpResult {
  final int statusCode;
  final String body;

  const _HttpResult({
    required this.statusCode,
    required this.body,
  });
}

Directory _resolvePackageRoot() {
  final direct = Directory.current;
  if (File('${direct.path}/test/fixtures/runtime_bridge_app.dart')
      .existsSync()) {
    return direct;
  }

  final nested = Directory('${direct.path}/packages/fletch_dev_tools');
  if (File('${nested.path}/test/fixtures/runtime_bridge_app.dart')
      .existsSync()) {
    return nested;
  }

  throw StateError(
    'Could not resolve fletch_dev_tools package root from ${Directory.current.path}',
  );
}
