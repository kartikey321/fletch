import 'dart:async';

import 'package:fletch_dev_tools/src/reload_engine/runtime/runtime_readiness.dart';
import 'package:test/test.dart';

void main() {
  group('RuntimeReadinessCoordinator', () {
    test('completes once all readiness signals are marked', () async {
      final coordinator = RuntimeReadinessCoordinator();
      addTearDown(coordinator.close);

      final readyFuture = coordinator.waitUntilReady(
        timeout: const Duration(seconds: 1),
      );

      coordinator.markListenerBound();
      coordinator.markVmServiceConnected();
      coordinator.markGenerationActive('gen-0005');

      final event = await readyFuture;
      expect(event.generationId, 'gen-0005');
    });

    test('times out if readiness is incomplete', () async {
      final coordinator = RuntimeReadinessCoordinator();
      addTearDown(coordinator.close);

      coordinator.markListenerBound();

      expect(
        () => coordinator.waitUntilReady(
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
