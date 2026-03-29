import 'package:fletch_dev_tools/src/change_analyzer.dart';
import 'package:fletch_dev_tools/src/reload_engine/classifier/change_classifier.dart';
import 'package:fletch_dev_tools/src/reload_engine/classifier/dependency_graph.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_strategy.dart';
import 'package:test/test.dart';

void main() {
  group('ChangeClassifier', () {
    const classifier = ChangeClassifier();

    test('maps restart-required analysis to restart strategy', () {
      final classification = classifier.classifyBatch(const [
        AnalysisResult(
          decision: ReloadDecision.requiresRestart,
          changes: [],
          reason: 'Dependencies changed',
        ),
        AnalysisResult(
          decision: ReloadDecision.requiresRestart,
          changes: [],
          reason: 'Entry point changed',
        ),
      ]);

      expect(classification.shouldRestart, isTrue);
      expect(classification.strategy, ReloadStrategy.restartRequired);
      expect(classification.invalidatedPaths, isEmpty);
      expect(
        classification.combinedReason,
        contains('Dependencies changed'),
      );
      expect(
        classification.combinedReason,
        contains('Entry point changed'),
      );
    });

    test('maps route reassemble hot-reload batch to routeGraphChange', () {
      final classification = classifier.classifyBatch(const [
        AnalysisResult(
          decision: ReloadDecision.canHotReload,
          changes: [],
          reason: 'Body-only changes',
          requiresRouteReassemble: true,
        ),
      ]);

      expect(classification.shouldRestart, isFalse);
      expect(classification.needsRouteReassemble, isTrue);
      expect(classification.strategy, ReloadStrategy.routeGraphChange);
      expect(classification.invalidatedPaths, isEmpty);
    });

    test('maps body-only hot reload to bodyOnlyHotSwap', () {
      final classification = classifier.classifyBatch(const [
        AnalysisResult(
          decision: ReloadDecision.canHotReload,
          changes: [],
          reason: 'Body-only changes',
          requiresRouteReassemble: false,
        ),
      ]);

      expect(classification.shouldRestart, isFalse);
      expect(classification.needsRouteReassemble, isFalse);
      expect(classification.strategy, ReloadStrategy.bodyOnlyHotSwap);
      expect(classification.invalidatedPaths, isEmpty);
    });

    test('prefers container shape strategy when graph reports DI touchpoint',
        () {
      final classification = classifier.classifyBatch(
        const [
          AnalysisResult(
            decision: ReloadDecision.canHotReload,
            changes: [],
            reason: 'Body-only changes',
            requiresRouteReassemble: false,
          ),
        ],
        dependencyImpact: const DependencyImpact(
          changedPaths: ['lib/src/registry.dart'],
          invalidatedPaths: [
            '/workspace/lib/src/registry.dart',
            '/workspace/lib/src/app.dart',
          ],
          routeGraphTouched: false,
          containerShapeTouched: true,
        ),
      );

      expect(classification.shouldRestart, isFalse);
      expect(classification.needsContainerMigration, isTrue);
      expect(classification.strategy, ReloadStrategy.containerShapeChange);
      expect(classification.invalidatedPaths, hasLength(2));
    });

    test('uses graph-expanded invalidation and route touchpoint', () {
      final classification = classifier.classifyBatch(
        const [
          AnalysisResult(
            decision: ReloadDecision.canHotReload,
            changes: [],
            reason: 'Body-only changes',
            requiresRouteReassemble: false,
          ),
        ],
        changedPaths: const ['lib/src/model.dart'],
        dependencyImpact: const DependencyImpact(
          changedPaths: ['lib/src/model.dart'],
          invalidatedPaths: [
            '/workspace/lib/src/model.dart',
            '/workspace/lib/src/routes.dart',
          ],
          routeGraphTouched: true,
          containerShapeTouched: false,
        ),
      );

      expect(classification.strategy, ReloadStrategy.routeGraphChange);
      expect(classification.needsRouteReassemble, isTrue);
      expect(classification.invalidatedPaths, hasLength(2));
    });

    test('falls back to changed paths when graph is unavailable', () {
      final classification = classifier.classifyBatch(
        const [
          AnalysisResult(
            decision: ReloadDecision.canHotReload,
            changes: [],
            reason: 'Body-only changes',
          ),
        ],
        changedPaths: const ['lib/b.dart', 'lib/a.dart', 'lib/b.dart'],
      );

      expect(
        classification.invalidatedPaths,
        equals(['lib/a.dart', 'lib/b.dart']),
      );
    });
  });
}
