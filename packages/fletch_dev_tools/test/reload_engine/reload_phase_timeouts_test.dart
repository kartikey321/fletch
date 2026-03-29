import 'package:fletch_dev_tools/src/reload_engine/runtime/reload_phase_timeouts.dart';
import 'package:fletch_dev_tools/src/reload_engine/transaction/reload_phase.dart';
import 'package:test/test.dart';

void main() {
  group('ReloadPhaseTimeouts', () {
    test('returns configured durations for active phases', () {
      const timeouts = ReloadPhaseTimeouts(
        classify: Duration(milliseconds: 10),
        compile: Duration(milliseconds: 20),
        stage: Duration(milliseconds: 30),
        activate: Duration(milliseconds: 40),
        retire: Duration(milliseconds: 50),
      );

      expect(timeouts.forPhase(ReloadPhase.classifying).inMilliseconds, 10);
      expect(timeouts.forPhase(ReloadPhase.compiling).inMilliseconds, 20);
      expect(timeouts.forPhase(ReloadPhase.staging).inMilliseconds, 30);
      expect(timeouts.forPhase(ReloadPhase.activating).inMilliseconds, 40);
      expect(timeouts.forPhase(ReloadPhase.retiring).inMilliseconds, 50);
    });

    test('terminal phases return short control timeout', () {
      const timeouts = ReloadPhaseTimeouts();
      expect(
        timeouts.forPhase(ReloadPhase.committed),
        const Duration(seconds: 1),
      );
      expect(
        timeouts.forPhase(ReloadPhase.failed),
        const Duration(seconds: 1),
      );
      expect(
        timeouts.forPhase(ReloadPhase.aborted),
        const Duration(seconds: 1),
      );
    });
  });
}
