import 'dart:async';

import '../transaction/generation_id.dart';
import '../transaction/reload_strategy.dart';

/// Migration lifecycle phases used by runtime state hooks.
enum ReloadMigrationPhase {
  prepare,
  commit,
  rollback,
}

/// Per-reload context passed to migration hooks.
class ReloadMigrationContext {
  final String transactionId;
  final GenerationId generationFrom;
  final GenerationId generationTo;
  final ReloadStrategy strategy;
  final List<String> changedPaths;
  final List<String> invalidatedPaths;
  final DateTime createdAt;

  ReloadMigrationContext({
    required this.transactionId,
    required this.generationFrom,
    required this.generationTo,
    required this.strategy,
    required List<String> changedPaths,
    required List<String> invalidatedPaths,
    required this.createdAt,
  })  : changedPaths = List.unmodifiable(changedPaths),
        invalidatedPaths = List.unmodifiable(invalidatedPaths);
}

/// Hook contract for state migration lifecycle.
abstract class ReloadStateMigrationHook {
  String get name;

  Future<void> onPrepare(ReloadMigrationContext context) async {}

  Future<void> onCommit(ReloadMigrationContext context) async {}

  Future<void> onRollback(
    ReloadMigrationContext context, {
    required String reason,
  }) async {}
}

/// Execution policy for migration hooks.
class ReloadMigrationPolicy {
  final bool enabled;
  final Duration prepareTimeout;
  final Duration commitTimeout;
  final Duration rollbackTimeout;

  const ReloadMigrationPolicy({
    this.enabled = false,
    this.prepareTimeout = const Duration(seconds: 2),
    this.commitTimeout = const Duration(seconds: 2),
    this.rollbackTimeout = const Duration(seconds: 2),
  });

  Duration timeoutFor(ReloadMigrationPhase phase) {
    switch (phase) {
      case ReloadMigrationPhase.prepare:
        return prepareTimeout;
      case ReloadMigrationPhase.commit:
        return commitTimeout;
      case ReloadMigrationPhase.rollback:
        return rollbackTimeout;
    }
  }
}

/// Structured migration execution failure.
class ReloadMigrationException implements Exception {
  final ReloadMigrationPhase phase;
  final String hookName;
  final Object cause;
  final StackTrace stackTrace;

  const ReloadMigrationException({
    required this.phase,
    required this.hookName,
    required this.cause,
    required this.stackTrace,
  });

  @override
  String toString() {
    return 'ReloadMigrationException('
        'phase=${phase.name}, hook=$hookName, cause=$cause)';
  }
}

/// Session runner for one transaction's migration lifecycle.
class ReloadMigrationSession {
  final ReloadMigrationPolicy _policy;
  final ReloadMigrationContext _context;
  final List<ReloadStateMigrationHook> _hooks;
  final List<ReloadStateMigrationHook> _preparedHooks = [];

  bool _prepareCompleted = false;
  bool _committed = false;
  bool _rolledBack = false;

  ReloadMigrationSession._(
    this._policy,
    this._context,
    this._hooks,
  );

  bool get isEnabled => _policy.enabled && _hooks.isNotEmpty;
  bool get didPrepare => _prepareCompleted;
  bool get didCommit => _committed;
  bool get didRollback => _rolledBack;

  Future<void> prepare() async {
    if (!isEnabled || _prepareCompleted) return;
    for (final hook in _hooks) {
      try {
        await _runHook(
          hook,
          ReloadMigrationPhase.prepare,
          () => hook.onPrepare(_context),
        );
        _preparedHooks.add(hook);
      } catch (e, st) {
        await _rollbackPreparedHooks(
          reason: 'prepare failed at hook ${hook.name}: $e',
        );
        if (e is ReloadMigrationException) rethrow;
        throw ReloadMigrationException(
          phase: ReloadMigrationPhase.prepare,
          hookName: hook.name,
          cause: e,
          stackTrace: st,
        );
      }
    }
    _prepareCompleted = true;
  }

  Future<void> commit() async {
    if (!isEnabled || _committed) return;
    if (!_prepareCompleted) {
      throw StateError('Cannot commit migration before prepare');
    }
    for (final hook in _hooks) {
      try {
        await _runHook(
          hook,
          ReloadMigrationPhase.commit,
          () => hook.onCommit(_context),
        );
      } catch (e, st) {
        await _rollbackPreparedHooks(
          reason: 'commit failed at hook ${hook.name}: $e',
        );
        if (e is ReloadMigrationException) rethrow;
        throw ReloadMigrationException(
          phase: ReloadMigrationPhase.commit,
          hookName: hook.name,
          cause: e,
          stackTrace: st,
        );
      }
    }
    _committed = true;
  }

  Future<void> rollback({
    required String reason,
  }) async {
    if (!isEnabled) return;
    await _rollbackPreparedHooks(reason: reason);
  }

  Future<void> _rollbackPreparedHooks({
    required String reason,
  }) async {
    if (_rolledBack) return;
    _rolledBack = true;
    ReloadMigrationException? firstError;

    for (final hook in _preparedHooks.reversed) {
      try {
        await _runHook(
          hook,
          ReloadMigrationPhase.rollback,
          () => hook.onRollback(_context, reason: reason),
        );
      } catch (e, st) {
        firstError ??= e is ReloadMigrationException
            ? e
            : ReloadMigrationException(
                phase: ReloadMigrationPhase.rollback,
                hookName: hook.name,
                cause: e,
                stackTrace: st,
              );
      }
    }

    if (firstError != null) {
      throw firstError;
    }
  }

  Future<void> _runHook(
    ReloadStateMigrationHook hook,
    ReloadMigrationPhase phase,
    Future<void> Function() op,
  ) async {
    final timeout = _policy.timeoutFor(phase);
    try {
      await op().timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'Migration hook ${hook.name} ${phase.name} timed out '
          'after ${timeout.inMilliseconds}ms',
          timeout,
        ),
      );
    } catch (e, st) {
      if (e is ReloadMigrationException) rethrow;
      throw ReloadMigrationException(
        phase: phase,
        hookName: hook.name,
        cause: e,
        stackTrace: st,
      );
    }
  }
}

/// Factory for migration sessions based on hook list + policy.
class ReloadMigrationRunner {
  final ReloadMigrationPolicy _policy;
  final List<ReloadStateMigrationHook> _hooks;

  ReloadMigrationRunner({
    ReloadMigrationPolicy policy = const ReloadMigrationPolicy(),
    List<ReloadStateMigrationHook> hooks = const [],
  })  : _policy = policy,
        _hooks = List.unmodifiable(hooks);

  bool get isEnabled => _policy.enabled && _hooks.isNotEmpty;
  int get hookCount => _hooks.length;

  ReloadMigrationSession createSession(ReloadMigrationContext context) {
    return ReloadMigrationSession._(
      _policy,
      context,
      _hooks,
    );
  }
}
