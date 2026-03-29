import 'generation_handle.dart';

/// Lease held for a request bound to a specific generation.
class GenerationLease {
  final String generationId;
  final void Function() _release;
  bool _released = false;

  GenerationLease({
    required this.generationId,
    required void Function() onRelease,
  }) : _release = onRelease;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// In-memory active generation pointer + in-flight accounting.
class ActiveGenerationStore {
  GenerationHandle? _active;
  final Map<String, int> _inFlight = {};
  final Set<String> _retiring = <String>{};

  GenerationHandle? get active => _active;

  bool get hasActive => _active != null;

  int inFlightFor(String generationId) => _inFlight[generationId] ?? 0;

  int get totalInFlight =>
      _inFlight.values.fold<int>(0, (sum, value) => sum + value);

  bool isRetiring(String generationId) => _retiring.contains(generationId);

  GenerationHandle initialize(GenerationHandle handle) {
    if (_active != null) {
      throw StateError('Active generation already initialized');
    }
    final activated = handle.markActivated();
    _active = activated;
    _inFlight.putIfAbsent(activated.id.value, () => 0);
    return activated;
  }

  GenerationHandle activate(GenerationHandle next) {
    final activated = next.markActivated();
    _active = activated;
    _inFlight.putIfAbsent(activated.id.value, () => 0);
    return activated;
  }

  void markRetiring(String generationId) {
    _retiring.add(generationId);
  }

  void completeRetire(String generationId) {
    _retiring.remove(generationId);
    _inFlight.remove(generationId);
  }

  GenerationLease beginRequest() {
    final current = _active;
    if (current == null) {
      throw StateError('Cannot begin request without active generation');
    }
    final id = current.id.value;
    _inFlight[id] = (_inFlight[id] ?? 0) + 1;
    return GenerationLease(
      generationId: id,
      onRelease: () {
        final currentValue = _inFlight[id] ?? 0;
        if (currentValue <= 1) {
          _inFlight[id] = 0;
        } else {
          _inFlight[id] = currentValue - 1;
        }
      },
    );
  }
}
