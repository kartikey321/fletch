import 'dart:async';

class RuntimeReadinessState {
  final bool listenerBound;
  final bool vmServiceConnected;
  final bool generationActive;
  final String? generationId;
  final DateTime updatedAt;

  const RuntimeReadinessState({
    required this.listenerBound,
    required this.vmServiceConnected,
    required this.generationActive,
    required this.generationId,
    required this.updatedAt,
  });

  bool get isReady => listenerBound && vmServiceConnected && generationActive;

  RuntimeReadinessState copyWith({
    bool? listenerBound,
    bool? vmServiceConnected,
    bool? generationActive,
    String? generationId,
    DateTime? updatedAt,
  }) {
    return RuntimeReadinessState(
      listenerBound: listenerBound ?? this.listenerBound,
      vmServiceConnected: vmServiceConnected ?? this.vmServiceConnected,
      generationActive: generationActive ?? this.generationActive,
      generationId: generationId ?? this.generationId,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
    );
  }
}

class RuntimeReadyEvent {
  final String generationId;
  final DateTime timestamp;

  const RuntimeReadyEvent({
    required this.generationId,
    required this.timestamp,
  });

  Map<String, Object?> toJson() => {
        'type': 'RuntimeReady',
        'generationId': generationId,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Readiness handshake coordinator for runtime plane startup.
class RuntimeReadinessCoordinator {
  final StreamController<RuntimeReadinessState> _stateController =
      StreamController<RuntimeReadinessState>.broadcast();

  RuntimeReadinessState _state = RuntimeReadinessState(
    listenerBound: false,
    vmServiceConnected: false,
    generationActive: false,
    generationId: null,
    updatedAt: DateTime.now().toUtc(),
  );

  RuntimeReadinessState get state => _state;

  Stream<RuntimeReadinessState> get states => _stateController.stream;

  void markListenerBound() {
    _emit(_state.copyWith(listenerBound: true));
  }

  void markVmServiceConnected() {
    _emit(_state.copyWith(vmServiceConnected: true));
  }

  void markGenerationActive(String generationId) {
    _emit(
      _state.copyWith(
        generationActive: true,
        generationId: generationId,
      ),
    );
  }

  Future<RuntimeReadyEvent> waitUntilReady({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_state.isReady && _state.generationId != null) {
      return RuntimeReadyEvent(
        generationId: _state.generationId!,
        timestamp: DateTime.now().toUtc(),
      );
    }

    final completer = Completer<RuntimeReadyEvent>();
    late final StreamSubscription<RuntimeReadinessState> sub;
    sub = states.listen((state) {
      if (!state.isReady || state.generationId == null) return;
      if (completer.isCompleted) return;
      completer.complete(
        RuntimeReadyEvent(
          generationId: state.generationId!,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      sub.cancel();
    });

    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        sub.cancel();
        throw TimeoutException(
          'Runtime readiness timeout after ${timeout.inMilliseconds}ms',
          timeout,
        );
      });
    } finally {
      if (!completer.isCompleted) {
        await sub.cancel();
      }
    }
  }

  Future<void> close() async {
    await _stateController.close();
  }

  void _emit(RuntimeReadinessState next) {
    _state = next;
    _stateController.add(next);
  }
}
