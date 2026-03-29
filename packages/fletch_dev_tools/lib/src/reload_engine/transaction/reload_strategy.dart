/// Strategy selected by change classifier.
enum ReloadStrategy {
  bodyOnlyHotSwap,
  routeGraphChange,
  containerShapeChange,
  restartRequired,
}

extension ReloadStrategyX on ReloadStrategy {
  static ReloadStrategy fromName(String name) {
    for (final value in ReloadStrategy.values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown ReloadStrategy: $name');
  }
}
