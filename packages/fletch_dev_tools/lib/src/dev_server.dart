import 'dart:async';
import 'dart:io';

import 'package:watcher/watcher.dart';

import 'change_batch_processor.dart';
import 'change_batch_queue.dart';
import 'change_analyzer.dart';
import 'dev_file_watcher.dart';
import 'hot_reloader.dart';
import 'process_manager.dart';
import 'reload_engine/reload_engine.dart';

/// Development server with hot restart and hot reload capabilities.
class FletchDevServer {
  final String _entryPoint;
  final int _port;
  final List<String> _watchDirs;
  final bool _verboseCompiler;
  final int _compilerMaxDiagnostics;
  final int _compilerMaxRecoveryAttempts;
  final Duration _compilerRecoveryBackoff;
  final ReloadMigrationPolicy _migrationPolicy;
  final ReloadPhaseTimeouts _phaseTimeouts;
  final ReloadMetricsSink _metrics;

  late final ProcessManager _processManager;
  late final DevFileWatcher _fileWatcher;
  late final HotReloader _hotReloader;
  late final ChangeAnalyzer _changeAnalyzer;
  late final ChangeClassifier _changeClassifier;
  late final DependencyGraphStore _dependencyGraph;
  late final IncrementalCompiler _incrementalCompiler;
  late final ReloadTransactionEngine _reloadEngine;
  late final ReloadMigrationRunner _migrationRunner;
  late final ActiveGenerationStore _generationStore;
  late final GenerationRetireManager _retireManager;
  RuntimeReadinessCoordinator _runtimeReadiness = RuntimeReadinessCoordinator();
  late final ChangeBatchProcessor _batchProcessor;
  StreamSubscription<ReloadEvent>? _reloadEventsSub;
  GenerationId _activeGeneration = const GenerationId('gen-000001');
  bool _runtimeHooksUnavailableLogged = false;

  FletchDevServer({
    required String entryPoint,
    int port = 3000,
    List<String> watchDirectories = const ['lib'],
    bool verboseCompiler = false,
    int compilerMaxDiagnostics = 80,
    int compilerMaxRecoveryAttempts = 1,
    Duration compilerRecoveryBackoff = const Duration(milliseconds: 120),
    ReloadMigrationPolicy migrationPolicy = const ReloadMigrationPolicy(),
    List<ReloadStateMigrationHook> migrationHooks = const [],
    ReloadPhaseTimeouts phaseTimeouts = const ReloadPhaseTimeouts(),
    ReloadMetricsSink metrics = const NoopReloadMetricsSink(),
  })  : _entryPoint = entryPoint,
        _port = port,
        _watchDirs = watchDirectories,
        _verboseCompiler = verboseCompiler,
        _compilerMaxDiagnostics = compilerMaxDiagnostics,
        _compilerMaxRecoveryAttempts = compilerMaxRecoveryAttempts,
        _compilerRecoveryBackoff = compilerRecoveryBackoff,
        _migrationPolicy = migrationPolicy,
        _phaseTimeouts = phaseTimeouts,
        _metrics = metrics {
    _processManager = ProcessManager(
      entryPoint: _entryPoint,
      port: _port,
    );

    _fileWatcher = DevFileWatcher(
      watchDirectories: _watchDirs,
      onChanged: _onFilesChanged,
    );

    _hotReloader = HotReloader();
    _changeAnalyzer = ChangeAnalyzer();
    _changeClassifier = ChangeClassifier();
    _dependencyGraph = DependencyGraphStore(
      workspaceRoot: Directory.current.path,
      packageName: _discoverPackageName(),
    );
    _incrementalCompiler = IncrementalCompiler(
      entryPoint: _entryPoint,
      verbose: _verboseCompiler,
      maxDiagnostics: _compilerMaxDiagnostics,
      maxRecoveryAttempts: _compilerMaxRecoveryAttempts,
      recoveryBackoff: _compilerRecoveryBackoff,
    );
    _reloadEngine = ReloadTransactionEngine(
      metrics: _metrics,
      journal: FileReloadTransactionJournal(
        '.dart_tool/fletch_dev_tools/reload_transactions.jsonl',
      ),
    );
    _migrationRunner = ReloadMigrationRunner(
      policy: _migrationPolicy,
      hooks: migrationHooks,
    );
    _generationStore = ActiveGenerationStore();
    _retireManager =
        GenerationRetireManager(_generationStore, metrics: _metrics);
    _batchProcessor = ChangeBatchProcessor(
      queue: ChangeBatchQueue(),
      handler: (batch) async {
        try {
          await _handleBatch(batch);
        } catch (e) {
          print('❌ Reload batch processing failed: $e');
        }
      },
    );
  }

  /// Start the development server.
  Future<void> start() async {
    print('╔════════════════════════════════════════╗');
    print('║   Fletch Development Server            ║');
    print('╚════════════════════════════════════════╝');
    print('');
    print('📂 Watching: ${_watchDirs.join(', ')}');
    print('🚀 Entry: $_entryPoint');
    print('🔌 Port: $_port');
    print(
        '🧩 Incremental compiler logs: ${_verboseCompiler ? 'verbose' : 'normal'}');
    print('🛠️  Compiler recovery: attempts=$_compilerMaxRecoveryAttempts '
        'maxDiagnostics=$_compilerMaxDiagnostics '
        'backoff=${_compilerRecoveryBackoff.inMilliseconds}ms');
    print('🧬 Migration hooks: ${_migrationRunner.hookCount} '
        '(enabled=${_migrationRunner.isEnabled})');
    print('⏱️  Phase timeouts: classify=${_phaseTimeouts.classify.inSeconds}s '
        'compile=${_phaseTimeouts.compile.inSeconds}s '
        'stage=${_phaseTimeouts.stage.inSeconds}s '
        'activate=${_phaseTimeouts.activate.inSeconds}s '
        'retire=${_phaseTimeouts.retire.inSeconds}s');
    print('');
    print('Press Ctrl+C to quit');
    print('');

    _reloadEventsSub = _reloadEngine.events.listen(_onReloadEvent);
    await _reloadEngine.start();
    _ensureInitialGeneration();
    _updateRuntimeGauges();

    // Start the server process
    await _processManager.start();
    _runtimeReadiness.markListenerBound();

    // Connect to VM service — retries until the child is ready
    final connected =
        await _hotReloader.connect(serviceUri: _processManager.vmServiceUri);
    if (connected) {
      _runtimeReadiness.markVmServiceConnected();
      print('🔥 Hot reload enabled');
      await _syncRuntimeActiveGeneration(_activeGeneration);
      try {
        final readyEvent = await _runtimeReadiness.waitUntilReady(
          timeout: Duration(seconds: 5),
        );
        print('✅ Runtime ready (${readyEvent.generationId})');
      } on TimeoutException catch (e) {
        print('⚠️  Runtime readiness timeout: $e');
      }
    } else {
      print('⚠️  Hot reload unavailable (using hot restart only)');
    }

    // Pre-warm AST cache for all watched .dart files so the first file event
    // has something to diff against (otherwise first save always shows "File changed").
    await _prewarmAstCache();

    // Start incremental frontend compiler session used for file-scoped
    // recompile gating before VM hot reload.
    await _startIncrementalCompiler();

    // Start watching for file changes
    await _fileWatcher.start();
    _metrics.setGauge(
        ReloadMetricNames.reloadQueueDepth, _batchProcessor.pendingDepth);
  }

  Future<void> _startIncrementalCompiler() async {
    try {
      await _incrementalCompiler.start();
      print('🧩 Incremental compiler ready');
    } catch (e) {
      print('⚠️  Incremental compiler unavailable: $e');
    }
  }

  /// Scans watched directories and runs a silent AST analysis on every .dart
  /// file to populate the cache before the watcher starts.
  Future<void> _prewarmAstCache() async {
    final dartFiles = <String>[];
    for (final dir in _watchDirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      await for (final entity in d.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          dartFiles.add(entity.path);
        }
      }
    }
    if (dartFiles.isNotEmpty) {
      // Warm AST and dependency graph in parallel so first save has both
      // structural diff and invalidation context.
      await Future.wait([
        Future.wait(dartFiles.map((f) => _changeAnalyzer.analyze(f))),
        _dependencyGraph.updateForPaths(dartFiles),
      ]);
      print('🧠 AST cache warmed (${dartFiles.length} files)');
      print('🧭 Dependency graph warmed (${dartFiles.length} files)');
    }
  }

  /// Stop the development server.
  Future<void> stop() async {
    await _fileWatcher.stop();
    await _incrementalCompiler.stop();
    await _hotReloader.disconnect();
    await _processManager.stop();
    await _reloadEventsSub?.cancel();
    await _reloadEngine.stop();
    await _runtimeReadiness.close();
    _runtimeReadiness = RuntimeReadinessCoordinator();
  }

  /// Handle batched file change events with AST-based analysis.
  Future<void> _onFilesChanged(List<WatchEvent> events) async {
    _metrics.setGauge(
      ReloadMetricNames.reloadQueueDepth,
      _batchProcessor.pendingDepth + events.length,
    );
    await _batchProcessor.enqueue(events);
    _metrics.setGauge(
        ReloadMetricNames.reloadQueueDepth, _batchProcessor.pendingDepth);
  }

  Future<void> _handleBatch(List<WatchEvent> events) async {
    final totalStopwatch = Stopwatch()..start();
    final detectStopwatch = Stopwatch()..start();
    final changedPaths = events.map((e) => e.path).toSet().toList()..sort();
    late ReloadTransaction transaction;
    try {
      print('');
      if (changedPaths.length == 1) {
        print('📝 File changed: ${changedPaths.first}');
      } else {
        print('📝 Files changed (${changedPaths.length}):');
        for (final path in changedPaths.take(8)) {
          print('   - $path');
        }
        if (changedPaths.length > 8) {
          print('   ... and ${changedPaths.length - 8} more');
        }
      }

      // Analyze each changed file once (incremental, file-scoped).
      List<AnalysisResult> analyses;
      final classifyStopwatch = Stopwatch()..start();
      try {
        analyses = await _withPhaseTimeout(
          ReloadPhase.classifying,
          () => Future.wait(
            changedPaths.map((path) => _changeAnalyzer.analyze(path)),
          ),
        );
      } on TimeoutException catch (e) {
        _metrics.incrementCounter(
          ReloadMetricNames.reloadTransactionsTotal,
          labels: {
            'status': 'failed',
            'strategy': ReloadStrategy.restartRequired.name,
          },
        );
        print('❌ Classification timed out: $e');
        return;
      } finally {
        classifyStopwatch.stop();
        _metrics.observeMs(
          ReloadMetricNames.reloadClassifyMs,
          classifyStopwatch.elapsedMilliseconds,
        );
      }

      // Show detected changes (up to a compact preview).
      var printedChanges = 0;
      final totalChanges = analyses.fold<int>(
        0,
        (sum, result) => sum + result.changes.length,
      );
      for (var i = 0; i < changedPaths.length; i++) {
        final result = analyses[i];
        if (result.changes.isEmpty) continue;
        print('🔍 Analyzing changes...');
        for (final change in result.changes.take(3)) {
          if (printedChanges >= 10) break;
          print('   [${changedPaths[i]}]');
          print('   $change');
          if (change.suggestion != null) {
            print('      💡 ${change.suggestion}');
          }
          printedChanges++;
        }
      }
      if (totalChanges > printedChanges) {
        print('   ... and ${totalChanges - printedChanges} more changes');
      }

      DependencyImpact dependencyImpact;
      try {
        dependencyImpact =
            await _withPhaseTimeout(ReloadPhase.classifying, () async {
          await _dependencyGraph.updateForPaths(changedPaths);
          return _dependencyGraph.planImpact(changedPaths);
        });
      } on TimeoutException catch (e) {
        _metrics.incrementCounter(
          ReloadMetricNames.reloadTransactionsTotal,
          labels: {
            'status': 'failed',
            'strategy': ReloadStrategy.restartRequired.name,
          },
        );
        print('❌ Dependency graph update timed out: $e');
        return;
      }
      detectStopwatch.stop();
      _metrics.observeMs(
        ReloadMetricNames.reloadDetectMs,
        detectStopwatch.elapsedMilliseconds,
      );

      final classification = _changeClassifier.classifyBatch(
        analyses,
        dependencyImpact: dependencyImpact,
        changedPaths: changedPaths,
      );
      if (classification.invalidatedPaths.length > changedPaths.length) {
        print(
          '🧭 Graph invalidation expanded: '
          '${changedPaths.length} -> ${classification.invalidatedPaths.length} file(s)',
        );
      }
      final forceRestartForMigration =
          classification.needsContainerMigration && !_migrationRunner.isEnabled;
      if (forceRestartForMigration) {
        print('⚠️  Container-shape change detected but migration hooks are '
            'disabled; falling back to hot restart');
      }
      transaction = await _withPhaseTimeout(
        ReloadPhase.classifying,
        () => _reloadEngine.submit(
          ChangeSet(changedPaths: changedPaths),
          strategy: classification.strategy,
          message: 'Analyzed ${changedPaths.length} changed file(s)',
        ),
      );

      // Try incremental hot reload when safe for all changed files.
      if (!classification.shouldRestart &&
          !forceRestartForMigration &&
          _hotReloader.isConnected) {
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.compiling,
          message: 'Running incremental compile gate',
        );
        ReloadMigrationSession? migrationSession;
        late final IncrementalCompileResult compileGate;
        final compileStopwatch = Stopwatch()..start();
        try {
          compileGate = await _withPhaseTimeout(
            ReloadPhase.compiling,
            () => _incrementalCompiler
                .compileInvalidated(classification.invalidatedPaths),
          );
        } on TimeoutException catch (e) {
          _metrics
              .incrementCounter(ReloadMetricNames.reloadCompileFailuresTotal);
          await _failTransactionIfNeeded(
            transaction,
            'Compile phase timeout: $e',
          );
          print('❌ Compile phase timed out; keeping last good generation');
          return;
        } finally {
          compileStopwatch.stop();
          _metrics.observeMs(
            ReloadMetricNames.reloadCompileMs,
            compileStopwatch.elapsedMilliseconds,
          );
        }
        if (!compileGate.success) {
          _metrics
              .incrementCounter(ReloadMetricNames.reloadCompileFailuresTotal);
          await _reloadEngine.failTransaction(
            transaction,
            message:
                'Incremental compile failed (${compileGate.invalidatedFileCount} file(s))',
          );
          print(
            '❌ Incremental compile failed (${compileGate.durationMs}ms, ${compileGate.invalidatedFileCount} file(s))',
          );
          final linesToPrint = _verboseCompiler
              ? compileGate.diagnostics
              : compileGate.diagnostics.take(8);
          for (final line in linesToPrint) {
            print('   $line');
          }
          if (!_verboseCompiler && compileGate.diagnostics.length > 8) {
            print(
                '   ... and ${compileGate.diagnostics.length - 8} more lines');
          }
          print(
              'ℹ️  Keeping previous server state (fix errors and save again)');
          return;
        }
        if (compileGate.invalidatedFileCount > 0) {
          print(
            '🧩 Incremental compile ok (${compileGate.durationMs}ms, ${compileGate.invalidatedFileCount} file(s))',
          );
        }
        if (compileGate.recoveredFromDesync) {
          print(
            '🛠️  Compiler session recovered from desync'
            '${compileGate.recoveryReason == null ? '' : ': ${compileGate.recoveryReason}'}',
          );
        }
        if (classification.needsContainerMigration) {
          migrationSession = _migrationRunner.createSession(
            ReloadMigrationContext(
              transactionId: transaction.transactionId,
              generationFrom: transaction.generationFrom,
              generationTo: transaction.generationTo,
              strategy: classification.strategy,
              changedPaths: changedPaths,
              invalidatedPaths: classification.invalidatedPaths,
              createdAt: DateTime.now().toUtc(),
            ),
          );
          print('🧬 Running migration prepare hooks...');
          try {
            await migrationSession.prepare();
          } catch (e) {
            await _failTransactionIfNeeded(
              transaction,
              'Migration prepare failed: $e',
            );
            print('❌ Migration prepare failed: $e');
            return;
          }
        }

        final strategy = classification.needsRouteReassemble
            ? 'incremental + route reassemble'
            : 'incremental (no route reassemble)';
        print('🔄 Hot reloading ($strategy)...');
        final stageStopwatch = Stopwatch()..start();
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.staging,
          message: 'Staging generation ${transaction.generationTo}',
        );
        final stagedGeneration = _stageGeneration(
          transaction,
          changedPaths,
          activationMode: 'hot-reload',
        );
        stageStopwatch.stop();
        _metrics.observeMs(
          ReloadMetricNames.reloadStageMs,
          stageStopwatch.elapsedMilliseconds,
        );
        if (migrationSession != null) {
          print('🧬 Running migration commit hooks...');
          try {
            await migrationSession.commit();
          } catch (e) {
            await _failTransactionIfNeeded(
              transaction,
              'Migration commit failed: $e',
            );
            await _rollbackMigrationSession(
              migrationSession,
              reason: 'migration commit failure: $e',
            );
            print('❌ Migration commit failed: $e');
            return;
          }
        }
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.activating,
          message: 'Applying hot reload',
        );
        late final HotReloadResult reloadResult;
        final activateStopwatch = Stopwatch()..start();
        try {
          reloadResult = await _withPhaseTimeout(
            ReloadPhase.activating,
            () => _hotReloader.reload(
              changedFiles: changedPaths,
              reassembleRoutes: classification.needsRouteReassemble,
            ),
          );
        } on TimeoutException catch (e) {
          _metrics.incrementCounter(
            ReloadMetricNames.reloadActivationFailuresTotal,
          );
          await _rollbackMigrationSession(
            migrationSession,
            reason: 'activation timeout: $e',
          );
          await _failTransactionIfNeeded(
            transaction,
            'Activation timeout during hot reload: $e',
          );
          transaction = await _reloadEngine.submit(
            ChangeSet(changedPaths: changedPaths),
            strategy: ReloadStrategy.restartRequired,
            message: 'Fallback after hot reload activation timeout',
          );
          print('⚠️  Hot reload timed out');
          print('🔄 Falling back to hot restart...');
          reloadResult = HotReloadResult(
            success: false,
            message: 'Activation timeout',
          );
        } finally {
          activateStopwatch.stop();
          _metrics.observeMs(
            ReloadMetricNames.reloadActivateMs,
            activateStopwatch.elapsedMilliseconds,
          );
        }
        if (reloadResult.success) {
          await _activateGeneration(stagedGeneration);
          transaction = await _advanceTransactionIdempotent(
            transaction,
            ReloadPhase.retiring,
            message: 'Retiring generation ${transaction.generationFrom}',
          );
          await _retireGeneration(transaction.generationFrom);
          transaction = await _advanceTransactionIdempotent(
            transaction,
            ReloadPhase.committed,
            message: 'Hot reload committed',
          );
          print('✅ Hot reload successful (${reloadResult.duration}ms)');
          return;
        } else {
          _metrics.incrementCounter(
              ReloadMetricNames.reloadActivationFailuresTotal);
          await _rollbackMigrationSession(
            migrationSession,
            reason: 'hot reload failed: ${reloadResult.message}',
          );
          await _reloadEngine.failTransaction(
            transaction,
            message: 'Hot reload failed: ${reloadResult.message}',
          );
          transaction = await _reloadEngine.submit(
            ChangeSet(changedPaths: changedPaths),
            strategy: ReloadStrategy.restartRequired,
            message: 'Fallback after hot reload failure',
          );
          print('⚠️  Hot reload failed: ${reloadResult.message}');
          print('🔄 Falling back to hot restart...');
        }
      } else if (!classification.shouldRestart) {
        print('⚠️  VM service disconnected - hot reload unavailable');
      }

      print(
        '🔄 Hot restarting (${classification.combinedReason.isEmpty ? 'File changed' : classification.combinedReason})...',
      );

      // Hot restart
      try {
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.compiling,
          message: 'Restart strategy selected',
        );
        final restartStageStopwatch = Stopwatch()..start();
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.staging,
          message: 'Preparing restart',
        );
        final stagedGeneration = _stageGeneration(
          transaction,
          changedPaths,
          activationMode: 'hot-restart',
        );
        restartStageStopwatch.stop();
        _metrics.observeMs(
          ReloadMetricNames.reloadStageMs,
          restartStageStopwatch.elapsedMilliseconds,
        );
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.activating,
          message: 'Restarting process',
        );
        final restartActivateStopwatch = Stopwatch()..start();
        await _withPhaseTimeout(ReloadPhase.activating, () async {
          await _incrementalCompiler.stop();
          await _hotReloader.disconnect();
          await _processManager.restart();
          await _hotReloader.connect(serviceUri: _processManager.vmServiceUri);
          if (_hotReloader.isConnected) {
            _runtimeReadiness.markVmServiceConnected();
          }
          await _startIncrementalCompiler();
        });
        restartActivateStopwatch.stop();
        _metrics.observeMs(
          ReloadMetricNames.reloadActivateMs,
          restartActivateStopwatch.elapsedMilliseconds,
        );
        await _activateGeneration(stagedGeneration);
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.retiring,
          message: 'Retiring generation ${transaction.generationFrom}',
        );
        await _retireGeneration(transaction.generationFrom);
        transaction = await _advanceTransactionIdempotent(
          transaction,
          ReloadPhase.committed,
          message: 'Restart committed',
        );
      } catch (e) {
        if (!transaction.phase.isTerminal) {
          await _failTransactionIfNeeded(
            transaction,
            'Restart failed: $e',
          );
        }
        _metrics
            .incrementCounter(ReloadMetricNames.reloadActivationFailuresTotal);
        print('❌ Restart failed: $e');
      }
    } finally {
      totalStopwatch.stop();
      _metrics.observeMs(
        ReloadMetricNames.reloadTotalMs,
        totalStopwatch.elapsedMilliseconds,
      );
      _updateRuntimeGauges();
    }
  }

  void _ensureInitialGeneration() {
    if (_generationStore.hasActive) {
      _runtimeReadiness.markGenerationActive(_generationStore.active!.id.value);
      _updateRuntimeGauges();
      return;
    }
    final initial = _generationStore.initialize(
      GenerationHandle(
        id: _activeGeneration,
        createdAt: DateTime.now().toUtc(),
        metadata: {
          'entryPoint': _entryPoint,
          'port': _port,
        },
      ),
    );
    _runtimeReadiness.markGenerationActive(initial.id.value);
    _updateRuntimeGauges();
  }

  GenerationHandle _stageGeneration(
    ReloadTransaction transaction,
    List<String> changedPaths, {
    required String activationMode,
  }) {
    return GenerationHandle(
      id: transaction.generationTo,
      createdAt: DateTime.now().toUtc(),
      metadata: {
        'strategy': transaction.strategy.name,
        'activationMode': activationMode,
        'changedFileCount': changedPaths.length,
      },
    );
  }

  Future<void> _activateGeneration(GenerationHandle staged) async {
    final activated = _generationStore.activate(staged);
    _activeGeneration = activated.id;
    _runtimeReadiness.markGenerationActive(activated.id.value);
    _updateRuntimeGauges();
    await _syncRuntimeActiveGeneration(activated.id);
  }

  Future<void> _syncRuntimeActiveGeneration(GenerationId generationId) async {
    final result = await _hotReloader.activateGeneration(generationId.value);
    if (!result.available) {
      if (!_runtimeHooksUnavailableLogged) {
        _runtimeHooksUnavailableLogged = true;
        print(
          'ℹ️  Runtime generation hooks unavailable '
          '(call configureDevHotReload(...) in your app to enable drain-safe reload; '
          'app.hotReload(...) still supports route reassemble)',
        );
      }
      return;
    }
    if (!result.success) {
      print('⚠️  Runtime activate generation failed: ${result.message}');
      return;
    }
    _runtimeHooksUnavailableLogged = false;
  }

  Future<void> _retireGeneration(GenerationId generationId) async {
    final runtimeRetire = await _hotReloader.retireGeneration(
      generationId.value,
      timeout: _phaseTimeouts.retire,
    );
    if (runtimeRetire.available) {
      if (!runtimeRetire.success) {
        print('⚠️  Runtime retire failed: ${runtimeRetire.message}');
      } else if (runtimeRetire.forced) {
        print(
          '⚠️  Forced retire ${runtimeRetire.generationId} '
          '(${runtimeRetire.remainingInFlight ?? 0} in-flight request(s) left)',
        );
      }
      _generationStore.markRetiring(generationId.value);
      _generationStore.completeRetire(generationId.value);
      _updateRuntimeGauges();
      return;
    }

    final retireResult = await _retireManager.retire(
      generationId.value,
      timeout: _phaseTimeouts.retire,
    );
    if (retireResult.forced) {
      print(
        '⚠️  Forced retire ${retireResult.generationId} '
        '(${retireResult.remainingInFlight} in-flight request(s) left)',
      );
    }
    _updateRuntimeGauges();
  }

  void _updateRuntimeGauges() {
    _metrics.setGauge(
      ReloadMetricNames.reloadInflightRequests,
      _generationStore.totalInFlight,
    );
    final active = _generationStore.active;
    if (active == null) return;
    final base = active.activatedAt ?? active.createdAt;
    final ageMs = DateTime.now().toUtc().difference(base).inMilliseconds;
    _metrics.setGauge(
      ReloadMetricNames.reloadGenerationActiveAgeMs,
      ageMs < 0 ? 0 : ageMs,
    );
  }

  void _onReloadEvent(ReloadEvent event) {
    switch (event.type) {
      case ReloadEventType.failed:
      case ReloadEventType.aborted:
      case ReloadEventType.committed:
        print(
          '🧾 [${event.transactionId}] ${event.type.name} ${event.phase.name} '
          '(${event.generationFrom} -> ${event.generationTo})'
          '${event.message == null ? '' : ': ${event.message}'}',
        );
        break;
      case ReloadEventType.lifecycle:
      case ReloadEventType.phaseChanged:
        // Keep normal output focused.
        break;
    }
  }

  Future<ReloadTransaction> _advanceTransactionIdempotent(
    ReloadTransaction transaction,
    ReloadPhase phase, {
    String? message,
  }) {
    return _withPhaseTimeout(
      phase,
      () => _reloadEngine.advanceTransaction(
        transaction,
        phase,
        message: message,
      ),
    );
  }

  Future<void> _failTransactionIfNeeded(
    ReloadTransaction transaction,
    String message,
  ) async {
    if (transaction.phase.isTerminal) return;
    await _withPhaseTimeout(
      ReloadPhase.failed,
      () => _reloadEngine.failTransaction(transaction, message: message),
    );
  }

  Future<void> _rollbackMigrationSession(
    ReloadMigrationSession? session, {
    required String reason,
  }) async {
    if (session == null || !session.didPrepare || session.didRollback) return;
    try {
      await session.rollback(reason: reason);
      _metrics.incrementCounter(ReloadMetricNames.reloadRollbacksTotal);
      print('🧬 Migration rollback completed');
    } catch (e) {
      print('⚠️  Migration rollback failed: $e');
    }
  }

  Future<T> _withPhaseTimeout<T>(
    ReloadPhase phase,
    Future<T> Function() op,
  ) {
    final timeout = _phaseTimeouts.forPhase(phase);
    return op().timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException(
          'Phase ${phase.name} exceeded timeout ${timeout.inMilliseconds}ms',
          timeout,
        );
      },
    );
  }

  String? _discoverPackageName() {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) return null;
    for (final line in pubspec.readAsLinesSync()) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('name:')) continue;
      final value = trimmed.substring('name:'.length).trim();
      if (value.isEmpty) return null;
      return value;
    }
    return null;
  }
}
