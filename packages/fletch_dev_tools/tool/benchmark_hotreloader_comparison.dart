import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fletch_dev_tools/src/dev_server.dart';
import 'package:fletch_dev_tools/src/reload_engine/reload_engine.dart';

/// Benchmark script comparing `package:hotreloader` and `fletch_dev_tools`
/// under equivalent synthetic edit workloads.
///
/// Usage (from `packages/fletch_dev_tools`):
///   dart run tool/benchmark_hotreloader_comparison.dart
///
/// Optional args:
///   --runs=5
///   --edits=8
///   --fixture=body|route|both
///
/// Notes:
/// - This benchmark is intentionally process-level for `hotreloader`.
/// - `fletch_dev_tools` side now uses in-process metrics harness for
///   deterministic latency capture via `ReloadMetricsSink`.
/// - `hotreloader` side still captures end-to-end latency from
///   "file edit written" to "onAfterReload signal observed in stdout".
void main(List<String> args) async {
  final config = _Config.fromArgs(args);

  stdout.writeln('=== Hot Reload Comparison Benchmark ===');
  stdout.writeln(
      'runs=${config.runs} edits=${config.edits} fixture=${config.fixture}');
  stdout.writeln('');

  final workspace = await _BenchmarkWorkspace.create();
  final runner = _BenchmarkRunner(workspace, config);

  try {
    final result = await runner.run();
    stdout.writeln(result.toPrettyString());
    final jsonOut = jsonEncode(result.toJson());
    stdout.writeln('\nJSON_RESULT: $jsonOut');
  } finally {
    await workspace.dispose();
  }
}

enum _FixtureKind { body, route, both }

class _Config {
  final int runs;
  final int edits;
  final _FixtureKind fixture;

  const _Config({
    required this.runs,
    required this.edits,
    required this.fixture,
  });

  static _Config fromArgs(List<String> args) {
    int runs = 5;
    int edits = 8;
    _FixtureKind fixture = _FixtureKind.both;

    for (final arg in args) {
      if (arg.startsWith('--runs=')) {
        runs = int.tryParse(arg.substring('--runs='.length)) ?? runs;
      } else if (arg.startsWith('--edits=')) {
        edits = int.tryParse(arg.substring('--edits='.length)) ?? edits;
      } else if (arg.startsWith('--fixture=')) {
        final v = arg.substring('--fixture='.length).toLowerCase();
        switch (v) {
          case 'body':
            fixture = _FixtureKind.body;
            break;
          case 'route':
            fixture = _FixtureKind.route;
            break;
          case 'both':
            fixture = _FixtureKind.both;
            break;
        }
      }
    }

    return _Config(runs: runs, edits: edits, fixture: fixture);
  }
}

class _BenchmarkRunner {
  final _BenchmarkWorkspace ws;
  final _Config config;

  _BenchmarkRunner(this.ws, this.config);

  void _debug(String message) {
    stdout.writeln('[benchmark-debug] $message');
  }

  Future<_BenchmarkResult> run() async {
    final fixtureKinds = switch (config.fixture) {
      _FixtureKind.body => <_FixtureKind>[_FixtureKind.body],
      _FixtureKind.route => <_FixtureKind>[_FixtureKind.route],
      _FixtureKind.both => <_FixtureKind>[
          _FixtureKind.body,
          _FixtureKind.route
        ],
    };

    final fletchSamples = <String, List<int>>{};
    final hotreloaderSamples = <String, List<int>>{};

    for (final kind in fixtureKinds) {
      final key = kind.name;
      fletchSamples[key] = <int>[];
      hotreloaderSamples[key] = <int>[];

      for (var run = 0; run < config.runs; run++) {
        stdout.writeln('--- [$key] run ${run + 1}/${config.runs} ---');

        final fletch = await _runFletchDevTools(kind);
        fletchSamples[key]!.addAll(fletch);

        final hot = await _runHotReloader(kind);
        hotreloaderSamples[key]!.addAll(hot);
      }
    }

    return _BenchmarkResult(
      runs: config.runs,
      editsPerRun: config.edits,
      fletchDevToolsSamplesMs: fletchSamples,
      hotreloaderSamplesMs: hotreloaderSamples,
    );
  }

  Future<List<int>> _runFletchDevTools(_FixtureKind kind) async {
    final port = await _reservePort();
    final appDir = await ws.createFletchFixture(kind, port: port);

    _debug(
        'fletch_dev_tools fixture=${kind.name} appDir=${appDir.path} port=$port');

    final metrics = _RecordingMetricsSink();
    final server = FletchDevServer(
      entryPoint: '${appDir.path}/bin/server.dart',
      port: port,
      watchDirectories: ['${appDir.path}/lib'],
      metrics: metrics,
    );

    final samples = <int>[];

    try {
      await server.start();
      await Future<void>.delayed(const Duration(seconds: 1));

      for (var i = 0; i < config.edits; i++) {
        final value = i + 2;
        _debug(
            'fletch_dev_tools editStart fixture=${kind.name} index=$i value=$value');
        final before = metrics.sampleCount(ReloadMetricNames.reloadTotalMs);

        await ws.applyEdit(appDir, kind, value);

        final elapsed = await metrics.waitForNextSample(
          ReloadMetricNames.reloadTotalMs,
          afterCount: before,
          timeout: const Duration(seconds: 25),
        );

        samples.add(elapsed);
        _debug(
          'fletch_dev_tools editDone fixture=${kind.name} index=$i '
          'elapsedMs=$elapsed metric=${ReloadMetricNames.reloadTotalMs}',
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      await server.stop();
    }

    return samples;
  }

  Future<List<int>> _runHotReloader(_FixtureKind kind) async {
    final port = await _reservePort();
    final appDir = await ws.createHotreloaderFixture(kind, port: port);

    final cmd = [
      'dart',
      '--enable-vm-service',
      'bin/server.dart',
    ];

    _debug('hotreloader fixture=${kind.name} appDir=${appDir.path} port=$port');
    _debug('hotreloader cmd=${cmd.join(' ')}');

    final proc = await Process.start(
      cmd.first,
      cmd.sublist(1),
      workingDirectory: appDir.path,
      environment: {'PORT': '$port'},
    );

    final reader = _ProcessReader(proc, debugName: 'hot:${kind.name}');
    final samples = <int>[];

    try {
      await reader.waitForAny(
        const [
          'HOTRELOADER_READY',
          'The Dart VM service is listening on',
        ],
        timeout: const Duration(seconds: 25),
      );

      // Give hotreloader watcher time to initialize before first edit.
      await Future<void>.delayed(const Duration(milliseconds: 700));

      // Wait for the hotreloader fixture watcher readiness signal.
      await reader.waitForAny(
        const ['HOTRELOADER_READY'],
        timeout: const Duration(seconds: 25),
      );

      for (var i = 0; i < config.edits; i++) {
        final value = i + 2;
        _debug(
            'hotreloader editStart fixture=${kind.name} index=$i value=$value');
        final sw = Stopwatch()..start();
        await ws.applyEdit(appDir, kind, value);

        final matched = await reader.waitForAny(
          const [
            'HOTRELOAD_OK',
            'HOTRELOAD_FAIL',
          ],
          timeout: const Duration(seconds: 25),
        );
        sw.stop();
        samples.add(sw.elapsedMilliseconds);
        _debug(
          'hotreloader editDone fixture=${kind.name} index=$i '
          'elapsedMs=${sw.elapsedMilliseconds} matched="$matched"',
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      await reader.dispose();
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
    }

    return samples;
  }

  Future<int> _reservePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}

class _ProcessReader {
  final Process process;
  final String debugName;
  final _buffer = StringBuffer();
  final _lines = <String>[];
  late final StreamSubscription _stdoutSub;
  late final StreamSubscription _stderrSub;

  _ProcessReader(this.process, {required this.debugName}) {
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
  }

  void _onLine(String line) {
    _lines.add(line);
    _buffer.writeln(line);
    stdout.writeln('[process:$debugName] $line');
  }

  Future<String> waitForAny(
    List<String> needles, {
    required Duration timeout,
  }) async {
    final start = DateTime.now();
    final end = start.add(timeout);
    while (DateTime.now().isBefore(end)) {
      for (final line in _lines.reversed.take(60)) {
        for (final needle in needles) {
          if (line.contains(needle)) {
            stdout.writeln(
              '[process:$debugName] waitForAny matched needle="$needle" '
              'line="$line" elapsedMs=${DateTime.now().difference(start).inMilliseconds}',
            );
            return line;
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    throw TimeoutException(
      '[$debugName] Timed out waiting for: ${needles.join(', ')} '
      '(elapsed=${elapsed}ms)\n'
      'Recent output:\n${_tail()}',
      timeout,
    );
  }

  String _tail({int lines = 80}) {
    final start = _lines.length > lines ? _lines.length - lines : 0;
    return _lines.sublist(start).join('\n');
  }

  Future<void> dispose() async {
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
  }
}

class _BenchmarkWorkspace {
  final Directory root;
  final Directory packageRoot;

  _BenchmarkWorkspace._(this.root, this.packageRoot);

  static Future<_BenchmarkWorkspace> create() async {
    final packageRoot = _findPackageRoot();
    final benchmarkRoot =
        Directory('${packageRoot.path}/test/hotreload_benchmark_workspace');
    await benchmarkRoot.create(recursive: true);
    final root = await benchmarkRoot
        .createTemp('run_${DateTime.now().millisecondsSinceEpoch}_');
    return _BenchmarkWorkspace._(root, packageRoot);
  }

  static Directory _findPackageRoot() {
    final cwd = Directory.current;
    if (File('${cwd.path}/pubspec.yaml').existsSync() &&
        Directory('${cwd.path}/bin').existsSync()) {
      return cwd;
    }
    final nested = Directory('${cwd.path}/packages/fletch_dev_tools');
    if (File('${nested.path}/pubspec.yaml').existsSync()) return nested;
    throw StateError(
        'Run from fletch_dev_tools package root or monorepo root.');
  }

  Future<Directory> createFletchFixture(_FixtureKind kind,
      {required int port}) async {
    final dir = await _createFixtureBase('fletch_${kind.name}');
    await _writeFletchServer(dir, port: port, kind: kind);
    await _writeTargetLib(dir, kind, seed: 1);
    return dir;
  }

  Future<Directory> createHotreloaderFixture(_FixtureKind kind,
      {required int port}) async {
    final dir = await _createFixtureBase('hot_${kind.name}');
    await _writeHotreloaderServer(dir, port: port, kind: kind);
    await _writeTargetLib(dir, kind, seed: 1);
    return dir;
  }

  Future<void> applyEdit(Directory appDir, _FixtureKind kind, int value) async {
    final file = File('${appDir.path}/lib/reload_target.dart');
    final content = await file.readAsString();

    final updated = switch (kind) {
      _FixtureKind.body =>
        content.replaceFirst(RegExp(r'return\s+\d+;'), 'return $value;'),
      _FixtureKind.route =>
        content.replaceFirst(RegExp(r"/value\d+"), '/value$value'),
      _FixtureKind.both => content
          .replaceFirst(RegExp(r'return\s+\d+;'), 'return $value;')
          .replaceFirst(RegExp(r"/value\d+"), '/value$value'),
    };

    final marker = '// edit-$value';
    final withMarker = _replaceOrAppendMarker(updated, marker);
    await file.writeAsString(withMarker, flush: true);

    final stat = await file.stat();
    stdout.writeln(
      '[benchmark-debug] applyEdit path=${file.path} kind=${kind.name} '
      'value=$value size=${stat.size} modified=${stat.modified.toIso8601String()}',
    );
  }

  Future<Directory> _createFixtureBase(String name) async {
    final dir = await Directory('${root.path}/$name').create(recursive: true);
    await Directory('${dir.path}/bin').create(recursive: true);
    await Directory('${dir.path}/lib').create(recursive: true);
    await _writeFixturePubspec(dir);
    await _runPubGet(dir);
    return dir;
  }

  Future<void> _writeFletchServer(
    Directory dir, {
    required int port,
    required _FixtureKind kind,
  }) async {
    final f = File('${dir.path}/bin/server.dart');
    await f.writeAsString('''
import 'dart:io';
import 'package:fletch/fletch.dart';
import 'package:fletch_dev_tools/fletch_dev_tools.dart';
import 'package:benchmark_fixture/reload_target.dart';

void registerRoutes(Fletch app) {
  app.get('/ping', (req, res) => res.text('ok'));
  mountRoutes(app);
}

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

  final p = int.tryParse(Platform.environment['PORT'] ?? '') ?? $port;
  await app.listen(p, address: InternetAddress.loopbackIPv4);
}
''');
  }

  Future<void> _writeHotreloaderServer(
    Directory dir, {
    required int port,
    required _FixtureKind kind,
  }) async {
    final f = File('${dir.path}/bin/server.dart');
    await f.writeAsString('''
import 'dart:io';
import 'package:fletch/fletch.dart';
import 'package:hotreloader/hotreloader.dart';
import 'package:benchmark_fixture/reload_target.dart';

Future<void> main() async {
  final app = Fletch(
    secureCookies: false,
    requestTimeout: const Duration(seconds: 6),
    shutdownTimeout: const Duration(seconds: 3),
  );

  final reloader = await HotReloader.create(
    debounceInterval: const Duration(milliseconds: 300),
    onAfterReload: (ctx) {
      final ok = ctx.result == HotReloadResult.Succeeded ||
          ctx.result == HotReloadResult.PartiallySucceeded;
      stdout.writeln(ok ? 'HOTRELOAD_OK' : 'HOTRELOAD_FAIL');
    },
  );
  stdout.writeln('HOTRELOADER_READY');

  app.get('/ping', (req, res) => res.text('ok'));
  mountRoutes(app);

  final p = int.tryParse(Platform.environment['PORT'] ?? '') ?? $port;
  await app.listen(p, address: InternetAddress.loopbackIPv4);

  ProcessSignal.sigint.watch().listen((_) {
    reloader.stop();
    exit(0);
  });
}
''');
  }

  Future<void> _writeTargetLib(Directory dir, _FixtureKind kind,
      {required int seed}) async {
    final f = File('${dir.path}/lib/reload_target.dart');
    await f.writeAsString('''
import 'package:fletch/fletch.dart';

int currentValue() {
  return $seed;
}

void mountRoutes(Fletch app) {
  app.get('/value1', (req, res) => res.text('v\${currentValue()}'));
}
''');
  }

  Future<void> _writeFixturePubspec(Directory dir) async {
    final f = File('${dir.path}/pubspec.yaml');
    await f.writeAsString('''
name: benchmark_fixture
description: Temporary benchmark fixture package
publish_to: "none"

environment:
  sdk: ^3.6.0

dependencies:
  fletch:
    path: ${_toPosixPath(packageRoot.parent.path)}/fletch
  fletch_dev_tools:
    path: ${_toPosixPath(packageRoot.path)}
  hotreloader: ^4.4.0

dependency_overrides:
  fletch:
    path: ${_toPosixPath(packageRoot.parent.path)}/fletch
''');
  }

  Future<void> _runPubGet(Directory dir) async {
    stdout.writeln('[benchmark-debug] pubGet start dir=${dir.path}');
    final proc = await Process.start(
      'dart',
      ['pub', 'get'],
      workingDirectory: dir.path,
    );

    final out = StringBuffer();
    final err = StringBuffer();

    final stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      out.writeln(line);
    });

    final stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      err.writeln(line);
    });

    final code = await proc.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    if (code != 0) {
      throw StateError(
        'Failed to run "dart pub get" in ${dir.path} (exit $code)\n'
        '--- pub get stdout ---\n${out.toString().trim()}\n'
        '--- pub get stderr ---\n${err.toString().trim()}',
      );
    }

    stdout.writeln('[benchmark-debug] pubGet done dir=${dir.path}');
  }

  String _toPosixPath(String path) => path.replaceAll('\\', '/');

  String _replaceOrAppendMarker(String content, String marker) {
    final markerRe = RegExp(r'// edit-\d+\s*$', multiLine: true);
    if (markerRe.hasMatch(content)) {
      return content.replaceFirst(markerRe, marker);
    }

    final trimmed = content.endsWith('\n') ? content : '$content\n';
    return '$trimmed$marker\n';
  }

  Future<void> dispose() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }

    final workspaceBase =
        Directory('${packageRoot.path}/test/hotreload_benchmark_workspace');
    if (workspaceBase.existsSync()) {
      final remaining = workspaceBase
          .listSync()
          .where((entity) =>
              entity is Directory || entity is File || entity is Link)
          .isNotEmpty;
      if (!remaining) {
        await workspaceBase.delete(recursive: true);
      }
    }
  }
}

class _RecordingMetricsSink implements ReloadMetricsSink {
  final Map<String, List<int>> observedMs = <String, List<int>>{};

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
    observedMs.putIfAbsent(name, () => <int>[]).add(milliseconds.round());
  }

  @override
  void setGauge(
    String name,
    num value, {
    Map<String, String> labels = const {},
  }) {}

  int sampleCount(String metric) => observedMs[metric]?.length ?? 0;

  Future<int> waitForNextSample(
    String metric, {
    required int afterCount,
    required Duration timeout,
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final list = observedMs[metric];
      if (list != null && list.length > afterCount) {
        return list.last;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
      'Timed out waiting for next metric sample: $metric (afterCount=$afterCount)',
      timeout,
    );
  }
}

class _BenchmarkResult {
  final int runs;
  final int editsPerRun;
  final Map<String, List<int>> fletchDevToolsSamplesMs;
  final Map<String, List<int>> hotreloaderSamplesMs;

  const _BenchmarkResult({
    required this.runs,
    required this.editsPerRun,
    required this.fletchDevToolsSamplesMs,
    required this.hotreloaderSamplesMs,
  });

  Map<String, Object?> toJson() {
    return {
      'runs': runs,
      'editsPerRun': editsPerRun,
      'fletchDevTools': _summaries(fletchDevToolsSamplesMs),
      'hotreloader': _summaries(hotreloaderSamplesMs),
    };
  }

  String toPrettyString() {
    final sb = StringBuffer();
    sb.writeln('=== Summary ===');
    for (final fixture
        in _unionKeys(fletchDevToolsSamplesMs, hotreloaderSamplesMs)) {
      final f = _summary(fletchDevToolsSamplesMs[fixture] ?? const []);
      final h = _summary(hotreloaderSamplesMs[fixture] ?? const []);

      sb.writeln('\n[$fixture]');
      sb.writeln('  fletch_dev_tools: ${_fmt(f)}');
      sb.writeln('  hotreloader:      ${_fmt(h)}');
      if (f != null && h != null && h.p50 > 0) {
        final ratio = f.p50 / h.p50;
        sb.writeln(
            '  p50 ratio (fletch/hotreloader): ${ratio.toStringAsFixed(2)}x');
      }
    }
    return sb.toString();
  }

  Map<String, Object?> _summaries(Map<String, List<int>> map) {
    final out = <String, Object?>{};
    for (final entry in map.entries) {
      out[entry.key] = _summary(entry.value)?.toJson();
    }
    return out;
  }

  static List<String> _unionKeys(
      Map<String, Object?> a, Map<String, Object?> b) {
    final keys = <String>{...a.keys, ...b.keys}.toList()..sort();
    return keys;
  }

  static _Stats? _summary(List<int> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    int pct(int p) {
      final idx =
          ((p / 100) * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
      return sorted[idx];
    }

    return _Stats(
      samples: sorted.length,
      min: sorted.first,
      p50: pct(50),
      p95: pct(95),
      max: sorted.last,
      mean: sorted.reduce((a, b) => a + b) / sorted.length,
    );
  }

  static String _fmt(_Stats? s) {
    if (s == null) return 'n/a';
    return 'n=${s.samples} min=${s.min}ms p50=${s.p50}ms p95=${s.p95}ms max=${s.max}ms mean=${s.mean.toStringAsFixed(1)}ms';
  }
}

class _Stats {
  final int samples;
  final int min;
  final int p50;
  final int p95;
  final int max;
  final double mean;

  const _Stats({
    required this.samples,
    required this.min,
    required this.p50,
    required this.p95,
    required this.max,
    required this.mean,
  });

  Map<String, Object?> toJson() => {
        'samples': samples,
        'minMs': min,
        'p50Ms': p50,
        'p95Ms': p95,
        'maxMs': max,
        'meanMs': mean,
      };
}
