/// Ordered phases in reload transaction lifecycle.
enum ReloadPhase {
  detected,
  classifying,
  compiling,
  staging,
  activating,
  retiring,
  committed,
  failed,
  aborted,
}

extension ReloadPhaseX on ReloadPhase {
  bool get isTerminal =>
      this == ReloadPhase.committed ||
      this == ReloadPhase.failed ||
      this == ReloadPhase.aborted;

  static ReloadPhase fromName(String name) {
    for (final value in ReloadPhase.values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown ReloadPhase: $name');
  }
}
