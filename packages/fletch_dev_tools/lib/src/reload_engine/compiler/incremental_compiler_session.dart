import 'dart:async';
import 'dart:io';

import 'package:frontend_server_client/frontend_server_client.dart';

/// Result of incremental compilation for a set of invalidated files.
class IncrementalCompileResult {
  final bool success;
  final int durationMs;
  final int invalidatedFileCount;
  final List<String> diagnostics;
  final bool recoveredFromDesync;
  final String? recoveryReason;

  const IncrementalCompileResult({
    required this.success,
    required this.durationMs,
    required this.invalidatedFileCount,
    this.diagnostics = const [],
    this.recoveredFromDesync = false,
    this.recoveryReason,
  });
}

/// Compile output normalized for testability.
class IncrementalCompilerCompileOutput {
  final int errorCount;
  final List<String> compilerOutputLines;

  IncrementalCompilerCompileOutput({
    required this.errorCount,
    required List<String> compilerOutputLines,
  }) : compilerOutputLines = List.unmodifiable(compilerOutputLines);
}

/// Immutable options used to start a compiler daemon client.
class IncrementalCompilerStartOptions {
  final String entryPoint;
  final String outputDillPath;
  final String platformKernelPath;
  final String packageConfigPath;
  final bool verbose;

  const IncrementalCompilerStartOptions({
    required this.entryPoint,
    required this.outputDillPath,
    required this.platformKernelPath,
    required this.packageConfigPath,
    required this.verbose,
  });
}

/// Minimal client contract for incremental compiler session operations.
abstract class IncrementalCompilerClient {
  Future<IncrementalCompilerCompileOutput> compile([List<Uri>? invalidated]);
  void accept();
  Future<void> reject();
  Future<void> shutdown();
  void kill({ProcessSignal processSignal = ProcessSignal.sigkill});
}

typedef IncrementalCompilerClientFactory = Future<IncrementalCompilerClient>
    Function(
  IncrementalCompilerStartOptions options,
);

/// Incremental frontend-server based compiler used as a compile gate before
/// attempting VM hot reload.
class IncrementalCompiler {
  final String _entryPoint;
  final String _packageConfigPath;
  final bool _verbose;
  final int _maxDiagnostics;
  final int _maxRecoveryAttempts;
  final Duration _recoveryBackoff;
  final IncrementalCompilerClientFactory _clientFactory;
  final Future<void> Function(Duration) _sleep;

  IncrementalCompilerClient? _client;

  IncrementalCompiler({
    required String entryPoint,
    String packageConfigPath = '.dart_tool/package_config.json',
    bool verbose = false,
    int maxDiagnostics = 80,
    int maxRecoveryAttempts = 1,
    Duration recoveryBackoff = const Duration(milliseconds: 120),
    IncrementalCompilerClientFactory? clientFactory,
    Future<void> Function(Duration)? sleep,
  })  : _entryPoint = entryPoint,
        _packageConfigPath = packageConfigPath,
        _verbose = verbose,
        _maxDiagnostics = _validateMaxDiagnostics(maxDiagnostics),
        _maxRecoveryAttempts = maxRecoveryAttempts,
        _recoveryBackoff = _validateRecoveryBackoff(recoveryBackoff),
        _clientFactory = clientFactory ?? _startFrontendClient,
        _sleep = sleep ?? _defaultSleep {
    if (maxRecoveryAttempts < 0) {
      throw ArgumentError.value(
        maxRecoveryAttempts,
        'maxRecoveryAttempts',
        'must be >= 0',
      );
    }
  }

  bool get isStarted => _client != null;

  /// Start incremental compiler session and perform baseline compile.
  Future<void> start() async {
    if (_client != null) return;
    _client = await _bootClient(throwOnBaselineError: true);
  }

  /// Compile only invalidated files. Non-dart files are ignored.
  Future<IncrementalCompileResult> compileInvalidated(
    List<String> changedPaths,
  ) async {
    final client = _client;
    if (client == null) {
      return const IncrementalCompileResult(
        success: true,
        durationMs: 0,
        invalidatedFileCount: 0,
      );
    }

    final invalidated = changedPaths
        .where((p) => p.endsWith('.dart'))
        .map((p) => File(p).absolute.uri)
        .toSet()
        .toList(growable: false);

    if (invalidated.isEmpty) {
      return const IncrementalCompileResult(
        success: true,
        durationMs: 0,
        invalidatedFileCount: 0,
      );
    }

    final stopwatch = Stopwatch()..start();
    final outcome = await _compileWithRecovery(client, invalidated);
    stopwatch.stop();

    final diagnostics =
        _boundDiagnostics(outcome.compileOutput.compilerOutputLines);
    return IncrementalCompileResult(
      success: outcome.success,
      durationMs: stopwatch.elapsedMilliseconds,
      invalidatedFileCount: invalidated.length,
      diagnostics: diagnostics,
      recoveredFromDesync: outcome.recoveredFromDesync,
      recoveryReason: outcome.recoveryReason,
    );
  }

  Future<void> stop() async {
    final client = _client;
    _client = null;
    if (client == null) return;
    await _disposeClient(client);
  }

  Future<_CompileAttemptOutcome> _compileWithRecovery(
    IncrementalCompilerClient client,
    List<Uri> invalidated,
  ) async {
    var activeClient = client;
    String? recoveryReason;
    var recoveredFromDesync = false;

    for (var attempt = 0; attempt <= _maxRecoveryAttempts; attempt++) {
      IncrementalCompilerCompileOutput output;
      try {
        output = await activeClient.compile(invalidated);
      } catch (e) {
        final reason = 'compile threw: $e';
        if (attempt >= _maxRecoveryAttempts) {
          return _CompileAttemptOutcome(
            success: false,
            compileOutput: IncrementalCompilerCompileOutput(
              errorCount: 1,
              compilerOutputLines: ['Compiler daemon compile call failed'],
            ),
            recoveredFromDesync: recoveredFromDesync,
            recoveryReason: recoveryReason ?? reason,
          );
        }
        await _sleepForRetry(attempt + 1);
        final recovered = await _recoverDaemon(reason);
        if (recovered == null) {
          return _CompileAttemptOutcome(
            success: false,
            compileOutput: IncrementalCompilerCompileOutput(
              errorCount: 1,
              compilerOutputLines: ['Compiler daemon recovery failed'],
            ),
            recoveredFromDesync: recoveredFromDesync,
            recoveryReason: recoveryReason ?? reason,
          );
        }
        activeClient = recovered;
        recoveredFromDesync = true;
        recoveryReason ??= reason;
        continue;
      }

      if (output.errorCount > 0) {
        await _rejectWithBestEffort(activeClient);
        return _CompileAttemptOutcome(
          success: false,
          compileOutput: output,
          recoveredFromDesync: recoveredFromDesync,
          recoveryReason: recoveryReason,
        );
      }

      try {
        activeClient.accept();
      } catch (e) {
        final reason = 'accept threw: $e';
        if (attempt >= _maxRecoveryAttempts) {
          return _CompileAttemptOutcome(
            success: false,
            compileOutput: IncrementalCompilerCompileOutput(
              errorCount: 1,
              compilerOutputLines: ['Compiler daemon accept call failed'],
            ),
            recoveredFromDesync: recoveredFromDesync,
            recoveryReason: recoveryReason ?? reason,
          );
        }
        await _sleepForRetry(attempt + 1);
        final recovered = await _recoverDaemon(reason);
        if (recovered == null) {
          return _CompileAttemptOutcome(
            success: false,
            compileOutput: IncrementalCompilerCompileOutput(
              errorCount: 1,
              compilerOutputLines: ['Compiler daemon recovery failed'],
            ),
            recoveredFromDesync: recoveredFromDesync,
            recoveryReason: recoveryReason ?? reason,
          );
        }
        activeClient = recovered;
        recoveredFromDesync = true;
        recoveryReason ??= reason;
        continue;
      }

      return _CompileAttemptOutcome(
        success: true,
        compileOutput: output,
        recoveredFromDesync: recoveredFromDesync,
        recoveryReason: recoveryReason,
      );
    }

    return _CompileAttemptOutcome(
      success: false,
      compileOutput: IncrementalCompilerCompileOutput(
        errorCount: 1,
        compilerOutputLines: [
          'Compiler daemon reached unexpected terminal state'
        ],
      ),
      recoveredFromDesync: recoveredFromDesync,
      recoveryReason: recoveryReason,
    );
  }

  Future<void> _sleepForRetry(int retryIndex) {
    final backoff = _backoffForRetry(retryIndex);
    if (backoff <= Duration.zero) return Future<void>.value();
    return _sleep(backoff);
  }

  Duration _backoffForRetry(int retryIndex) {
    if (_recoveryBackoff <= Duration.zero) return Duration.zero;
    if (retryIndex <= 0) return Duration.zero;
    return Duration(
      microseconds: _recoveryBackoff.inMicroseconds * retryIndex,
    );
  }

  static int _validateMaxDiagnostics(int value) {
    if (value <= 0) {
      throw ArgumentError.value(
        value,
        'maxDiagnostics',
        'must be > 0',
      );
    }
    return value;
  }

  static Duration _validateRecoveryBackoff(Duration value) {
    if (value.isNegative) {
      throw ArgumentError.value(
        value,
        'recoveryBackoff',
        'must be >= Duration.zero',
      );
    }
    return value;
  }

  static Future<void> _defaultSleep(Duration duration) {
    return Future<void>.delayed(duration);
  }

  Future<IncrementalCompilerClient> _bootClient({
    required bool throwOnBaselineError,
  }) async {
    final outputDir = Directory('.dart_tool/fletch_dev_tools')
      ..createSync(recursive: true);
    final options = IncrementalCompilerStartOptions(
      entryPoint: _entryPoint,
      outputDillPath: '${outputDir.path}/incremental.dill',
      platformKernelPath: _platformKernelPath(),
      packageConfigPath: _packageConfigPath,
      verbose: _verbose,
    );
    final client = await _clientFactory(options);

    final baseline = await client.compile();
    if (baseline.errorCount > 0) {
      await _rejectWithBestEffort(client);
      if (throwOnBaselineError) {
        throw StateError(
          'Initial incremental compile failed with ${baseline.errorCount} error(s).',
        );
      }
      return client;
    }
    client.accept();
    return client;
  }

  Future<IncrementalCompilerClient?> _recoverDaemon(String reason) async {
    final existing = _client;
    if (existing != null) {
      await _disposeClient(existing);
      _client = null;
    }
    try {
      final recovered = await _bootClient(throwOnBaselineError: false);
      _client = recovered;
      return recovered;
    } catch (_) {
      _client = null;
      return null;
    }
  }

  Future<void> _rejectWithBestEffort(IncrementalCompilerClient client) async {
    try {
      await client.reject();
    } catch (_) {
      // Best effort only. A failed reject is usually recoverable on next cycle.
    }
  }

  Future<void> _disposeClient(IncrementalCompilerClient client) async {
    try {
      await client.shutdown();
    } catch (_) {
      client.kill(processSignal: ProcessSignal.sigkill);
    }
  }

  List<String> _boundDiagnostics(List<String> lines) {
    if (_verbose) {
      return List.unmodifiable(lines);
    }
    if (lines.length <= _maxDiagnostics) {
      return List.unmodifiable(lines);
    }
    final clipped = <String>[
      ...lines.take(_maxDiagnostics),
      '... diagnostics truncated (${lines.length - _maxDiagnostics} line(s) omitted)',
    ];
    return List.unmodifiable(clipped);
  }

  String _platformKernelPath() {
    final sdkBin = File(Platform.resolvedExecutable).parent;
    final sdkDir = sdkBin.parent.path;
    return '$sdkDir/lib/_internal/vm_platform_strong.dill';
  }

  static Future<IncrementalCompilerClient> _startFrontendClient(
    IncrementalCompilerStartOptions options,
  ) async {
    final client = await FrontendServerClient.start(
      options.entryPoint,
      options.outputDillPath,
      options.platformKernelPath,
      packagesJson: options.packageConfigPath,
      target: 'vm',
      verbose: options.verbose,
      printIncrementalDependencies: false,
    );
    return _FrontendServerClientAdapter(client);
  }
}

class _CompileAttemptOutcome {
  final bool success;
  final IncrementalCompilerCompileOutput compileOutput;
  final bool recoveredFromDesync;
  final String? recoveryReason;

  const _CompileAttemptOutcome({
    required this.success,
    required this.compileOutput,
    required this.recoveredFromDesync,
    required this.recoveryReason,
  });
}

class _FrontendServerClientAdapter implements IncrementalCompilerClient {
  final FrontendServerClient _client;

  _FrontendServerClientAdapter(this._client);

  @override
  Future<IncrementalCompilerCompileOutput> compile(
      [List<Uri>? invalidated]) async {
    final result = await _client.compile(invalidated);
    return IncrementalCompilerCompileOutput(
      errorCount: result.errorCount,
      compilerOutputLines: result.compilerOutputLines.toList(growable: false),
    );
  }

  @override
  void accept() {
    _client.accept();
  }

  @override
  Future<void> reject() {
    return _client.reject();
  }

  @override
  Future<void> shutdown() {
    return _client.shutdown();
  }

  @override
  void kill({ProcessSignal processSignal = ProcessSignal.sigkill}) {
    _client.kill(processSignal: processSignal);
  }
}
