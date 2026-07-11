// Tests the low-level primitives that fletch_dev_tools' dev-reload addon
// composes to fix two real bugs: repeated `app.use(...)` calls duplicating
// global middleware forever, and repeated DI registration crashing GetIt.
// See packages/fletch_dev_tools/lib/src/runtime/fletch_dev_hot_reload.dart.

import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Dev-reload primitives', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('clearMiddleware() removes previously registered global middleware',
        () async {
      var callCount = 0;
      harness.app.use((req, res, next) async {
        callCount++;
        await next();
      });
      harness.app.get('/ping', (req, res) => res.text('ok'));

      await harness.get('/ping');
      expect(callCount, 1);

      // Simulates what a dev-reload cycle does: clear, then re-run whatever
      // registered middleware/routes in the first place.
      harness.app.clearMiddleware();
      harness.app.use((req, res, next) async {
        callCount++;
        await next();
      });

      await harness.get('/ping');
      // If clearMiddleware() didn't work, the original middleware would
      // still be registered too, and this second request would increment
      // callCount by 2 (both the stale and the fresh middleware firing).
      expect(callCount, 2);
    });

    test(
        'repeated clearMiddleware() + re-registration across many cycles '
        'never accumulates', () async {
      final counters = <int>[];

      for (var cycle = 0; cycle < 5; cycle++) {
        harness.app.clearMiddleware();
        var thisCounterCycleCalls = 0;
        harness.app.use((req, res, next) async {
          thisCounterCycleCalls++;
          counters.add(thisCounterCycleCalls);
          await next();
        });
      }
      harness.app.get('/ping', (req, res) => res.text('ok'));

      await harness.get('/ping');

      // Only the last cycle's middleware should still be registered and
      // fire exactly once — not five accumulated copies from every cycle.
      expect(counters, [1]);
    });

    test(
        'a GetIt scope pushed and dropped per reload cycle allows the same '
        'type to be re-registered without crashing', () async {
      const scopeName = 'test_reload_scope';

      void registerServiceForThisCycle(String value) {
        harness.app.registerLazySingleton<String>(() => value);
      }

      // First "reload" cycle.
      harness.app.container.pushNewScope(scopeName: scopeName);
      registerServiceForThisCycle('cycle-1');
      expect(harness.app.container<String>(), 'cycle-1');

      // Second "reload" cycle — without dropping and re-pushing the scope,
      // this would throw "already registered" against the live container.
      await harness.app.container.dropScope(scopeName);
      harness.app.container.pushNewScope(scopeName: scopeName);
      registerServiceForThisCycle('cycle-2');
      expect(harness.app.container<String>(), 'cycle-2');

      // Third cycle, to be sure this isn't a one-time fluke.
      await harness.app.container.dropScope(scopeName);
      harness.app.container.pushNewScope(scopeName: scopeName);
      registerServiceForThisCycle('cycle-3');
      expect(harness.app.container<String>(), 'cycle-3');
    });
  });
}
