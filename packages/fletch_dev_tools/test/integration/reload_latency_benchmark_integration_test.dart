import 'dart:async';
import 'dart:io';

import 'package:fletch_dev_tools/src/dev_server.dart';
import 'package:fletch_dev_tools/src/reload_engine/reload_engine.dart';
import 'package:test/test.dart';

typedef WorkspaceMutator = Future<void> Function(Directory workspace, int step);

void main() {
  group('Reload latency benchmark integration', () {
    test('reports body-only reload_total_ms on a real fixture app', () async {
      final workspace = await _createBodyOnlyFixtureWorkspace();
      await _runBenchmarkScenario(
        fixture: 'body_only',
        workspace: workspace,
        mutate: (dir, step) => _mutateBodyFile(dir, nextValue: step + 2),
      );
    });

    test('reports route-graph reload_total_ms on a real fixture app', () async {
      final workspace = await _createRouteGraphFixtureWorkspace();
      await _runBenchmarkScenario(
        fixture: 'route_graph',
        workspace: workspace,
        mutate: (dir, step) => _mutateRouteGraphFile(dir, nextValue: step + 2),
      );
    });
  });
}

Future<void> _runBenchmarkScenario({
  required String fixture,
  required Directory workspace,
  required WorkspaceMutator mutate,
}) async {
  final port = await _reservePort();
  final metrics = _RecordingMetricsSink();

  final server = FletchDevServer(
    entryPoint: '${workspace.path}/bin/server.dart',
    port: port,
    watchDirectories: ['${workspace.path}/lib'],
    metrics: metrics,
  );

  try {
    await server.start();
    await Future<void>.delayed(const Duration(seconds: 1));

    const edits = 12;
    var expectedSamples = 0;
    for (var i = 0; i < edits; i++) {
      await mutate(workspace, i);
      expectedSamples++;
      await _waitForMetricSamples(
        metrics,
        metric: ReloadMetricNames.reloadTotalMs,
        atLeast: expectedSamples,
      );
    }

    final totalMs =
        metrics.observedMs[ReloadMetricNames.reloadTotalMs] ?? const <num>[];
    expect(totalMs.length, greaterThanOrEqualTo(edits));

    final p50 = _percentile(totalMs, 50);
    final p95 = _percentile(totalMs, 95);

    expect(p50, greaterThan(0));
    expect(p95, lessThan(10000));

    // ignore: avoid_print
    print(
      'RELOAD_BENCHMARK fixture=$fixture '
      'samples=${totalMs.length} p50=${p50.toStringAsFixed(1)}ms '
      'p95=${p95.toStringAsFixed(1)}ms values=${totalMs.map((v) => v.toStringAsFixed(0)).join(',')}',
    );
  } finally {
    await server.stop();
    await workspace.delete(recursive: true);
  }
}

class _RecordingMetricsSink implements ReloadMetricsSink {
  final Map<String, List<num>> observedMs = <String, List<num>>{};

  @override
  void incrementCounter(
    String name, {
    Map<String, String> labels = const {},
    int by = 1,
  }) {}

  @override
  void observeMs(
    String name,
    num milliseconds, {
    Map<String, String> labels = const {},
  }) {
    observedMs.putIfAbsent(name, () => <num>[]).add(milliseconds);
  }

  @override
  void setGauge(
    String name,
    num value, {
    Map<String, String> labels = const {},
  }) {}
}

Future<void> _waitForMetricSamples(
  _RecordingMetricsSink metrics, {
  required String metric,
  required int atLeast,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final len = metrics.observedMs[metric]?.length ?? 0;
    if (len >= atLeast) return;
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  final current = metrics.observedMs[metric]?.length ?? 0;
  throw TimeoutException(
    'Timed out waiting for metric $metric samples ($current/$atLeast)',
    timeout,
  );
}

Future<Directory> _createBodyOnlyFixtureWorkspace() async {
  final root = _resolvePackageRoot();
  final base = Directory('${root.path}/test/reload_bench_tmp');
  await base.create(recursive: true);
  final dir = await base.createTemp('fletch_reload_bench_body_');
  await Directory('${dir.path}/bin').create(recursive: true);
  await Directory('${dir.path}/lib').create(recursive: true);

  final entryPoint = File('${dir.path}/bin/server.dart');
  await entryPoint.writeAsString('''
import 'dart:io';
import 'package:fletch/fletch.dart';
import 'package:fletch_dev_tools/fletch_dev_tools.dart';
import '../lib/reload_target.dart';

void _register(Fletch app) {
  app.get('/ping', (req, res) => res.text('ok'));
  app.get('/value', (req, res) => res.text('v\${currentValue()}'));
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

  final targetFile = File('${dir.path}/lib/reload_target.dart');
  await targetFile.writeAsString('''
int currentValue() {
  return 1;
}
''');

  return dir;
}

Future<Directory> _createRouteGraphFixtureWorkspace() async {
  final root = _resolvePackageRoot();
  final base = Directory('${root.path}/test/reload_bench_tmp');
  await base.create(recursive: true);
  final dir = await base.createTemp('fletch_reload_bench_route_');
  await Directory('${dir.path}/bin').create(recursive: true);
  await Directory('${dir.path}/lib').create(recursive: true);

  final entryPoint = File('${dir.path}/bin/server.dart');
  await entryPoint.writeAsString('''
import 'dart:io';
import 'package:fletch/fletch.dart';
import 'package:fletch_dev_tools/fletch_dev_tools.dart';
import '../lib/routes.dart';

Future<void> main() async {
  final app = Fletch(
    secureCookies: false,
    requestTimeout: const Duration(seconds: 6),
    shutdownTimeout: const Duration(seconds: 3),
  );
  configureDevHotReload(
    app,
    registerRoutes: () => registerRoutes(app),
    enabled: true,
  );
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 0;
  await app.listen(port == 0 ? 0 : port, address: InternetAddress.loopbackIPv4);
}
''');

  final routesFile = File('${dir.path}/lib/routes.dart');
  await routesFile.writeAsString('''
import 'package:fletch/fletch.dart';

void registerRoutes(Fletch app) {
  app.get('/ping', (req, res) => res.text('ok'));
  app.get('/value', (req, res) => res.text('route-v\${routeValue()}'));
}

int routeValue() {
  return 1;
}
''');

  return dir;
}

Future<void> _mutateBodyFile(
  Directory workspace, {
  required int nextValue,
}) async {
  final file = File('${workspace.path}/lib/reload_target.dart');
  final original = await file.readAsString();
  final updated = original.replaceFirst(
    RegExp(r'return\s+\d+;'),
    'return $nextValue;',
  );
  if (updated == original) {
    throw StateError('Could not update fixture body file');
  }
  await file.writeAsString(
    '$updated\n// bench-body-${DateTime.now().microsecondsSinceEpoch}\n',
  );
}

Future<void> _mutateRouteGraphFile(
  Directory workspace, {
  required int nextValue,
}) async {
  final file = File('${workspace.path}/lib/routes.dart');
  final original = await file.readAsString();
  final updated = original.replaceFirst(
    RegExp(r'return\s+\d+;'),
    'return $nextValue;',
  );
  if (updated == original) {
    throw StateError('Could not update route graph fixture file');
  }
  await file.writeAsString(
    '$updated\n// bench-route-${DateTime.now().microsecondsSinceEpoch}\n',
  );
}

num _percentile(List<num> values, int percentile) {
  if (values.isEmpty) {
    throw ArgumentError('Cannot compute percentile of empty list');
  }
  final sorted = [...values]..sort();
  final rank = (percentile / 100) * (sorted.length - 1);
  final index = rank.round().clamp(0, sorted.length - 1);
  return sorted[index];
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
