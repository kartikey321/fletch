import '../../change_analyzer.dart';
import 'dependency_graph.dart';
import '../transaction/reload_strategy.dart';

/// Classifier output for a coalesced analysis batch.
class ChangeClassification {
  final ReloadStrategy strategy;
  final bool shouldRestart;
  final bool needsRouteReassemble;
  final bool needsContainerMigration;
  final List<String> invalidatedPaths;
  final String combinedReason;

  const ChangeClassification({
    required this.strategy,
    required this.shouldRestart,
    required this.needsRouteReassemble,
    required this.needsContainerMigration,
    required this.invalidatedPaths,
    required this.combinedReason,
  });
}

/// Maps AST/file analyses into runtime reload strategy.
class ChangeClassifier {
  const ChangeClassifier();

  ChangeClassification classifyBatch(
    Iterable<AnalysisResult> analyses, {
    DependencyImpact? dependencyImpact,
    Iterable<String> changedPaths = const [],
  }) {
    final list = analyses.toList(growable: false);
    final shouldRestart = list.any(
      (result) => result.decision == ReloadDecision.requiresRestart,
    );
    final routeReassembleFromAnalysis = list.any(
      (result) => result.requiresRouteReassemble,
    );
    final routeReassembleFromGraph =
        dependencyImpact?.routeGraphTouched ?? false;
    final needsRouteReassemble =
        routeReassembleFromAnalysis || routeReassembleFromGraph;
    final needsContainerMigration =
        dependencyImpact?.containerShapeTouched ?? false;
    final combinedReason = list
        .where((result) => result.decision == ReloadDecision.requiresRestart)
        .map((result) => result.reason)
        .where((reason) => reason.isNotEmpty)
        .take(3)
        .join('; ');
    final invalidatedPaths = _deriveInvalidatedPaths(
      dependencyImpact,
      changedPaths,
    );

    final strategy = _deriveStrategy(
      shouldRestart: shouldRestart,
      needsRouteReassemble: needsRouteReassemble,
      needsContainerMigration: needsContainerMigration,
    );
    return ChangeClassification(
      strategy: strategy,
      shouldRestart: shouldRestart,
      needsRouteReassemble: needsRouteReassemble,
      needsContainerMigration: needsContainerMigration,
      invalidatedPaths: invalidatedPaths,
      combinedReason: combinedReason,
    );
  }

  ReloadStrategy _deriveStrategy({
    required bool shouldRestart,
    required bool needsRouteReassemble,
    required bool needsContainerMigration,
  }) {
    if (shouldRestart) return ReloadStrategy.restartRequired;
    if (needsContainerMigration) return ReloadStrategy.containerShapeChange;
    if (needsRouteReassemble) return ReloadStrategy.routeGraphChange;
    return ReloadStrategy.bodyOnlyHotSwap;
  }

  List<String> _deriveInvalidatedPaths(
    DependencyImpact? dependencyImpact,
    Iterable<String> changedPaths,
  ) {
    final fromGraph = dependencyImpact?.invalidatedPaths;
    if (fromGraph != null && fromGraph.isNotEmpty) {
      return fromGraph;
    }
    final fallback = changedPaths.toSet().toList()..sort();
    return List.unmodifiable(fallback);
  }
}
