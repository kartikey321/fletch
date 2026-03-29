import '../transaction/reload_phase.dart';

/// Timeout budget for each transaction phase.
class ReloadPhaseTimeouts {
  final Duration classify;
  final Duration compile;
  final Duration stage;
  final Duration activate;
  final Duration retire;

  const ReloadPhaseTimeouts({
    this.classify = const Duration(seconds: 2),
    this.compile = const Duration(seconds: 20),
    this.stage = const Duration(seconds: 3),
    this.activate = const Duration(seconds: 10),
    this.retire = const Duration(seconds: 3),
  });

  Duration forPhase(ReloadPhase phase) {
    switch (phase) {
      case ReloadPhase.classifying:
        return classify;
      case ReloadPhase.compiling:
        return compile;
      case ReloadPhase.staging:
        return stage;
      case ReloadPhase.activating:
        return activate;
      case ReloadPhase.retiring:
        return retire;
      case ReloadPhase.detected:
      case ReloadPhase.committed:
      case ReloadPhase.failed:
      case ReloadPhase.aborted:
        return const Duration(seconds: 1);
    }
  }
}
