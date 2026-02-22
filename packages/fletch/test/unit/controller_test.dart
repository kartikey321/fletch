import 'package:fletch/fletch.dart'; // Exported via fletch.dart -> services.dart
import 'package:test/test.dart';

// Simple controller for testing
class TestController extends Controller {
  @override
  void registerRoutes(ControllerOptions options) {
    options.get('/hello', (req, res) => res.text('Hello from controller'));
    options.post('/echo', (req, res) async {
      // simple body echo
      // Not strictly needed for routing test but good for sanity
      res.text('echo');
    });
  }
}

void main() {
  group('Controller', () {
    late Fletch app;

    setUp(() {
      app = Fletch();
    });

    tearDown(() async {
      await app.close();
    });

    test('registers routes on Fletch app', () async {
      app.useController('/api', TestController());

      // Verify route is registered by finding it in the router
      // Since router is internal/abstracted, we can't easily query it directly without internal helpers,
      // but we can rely on integration-style check or trust internal structures if accessible.
      // However, unit tests here might need to mock or inspect router.
      // Or we can mock the request processing.

      // Fletch uses a RadixRouter by default.
      // Let's create a partial request object or just inspect the router if possible.
      // Given we are in unit tests, we rely on public API or implementation details if feasible.

      // Let's rely on finding the route via the router.
      final match = app.router.findRoute('GET', '/api/hello');
      expect(match, isNotNull);
    });

    test('registers routes with correct prefix', () async {
      app.useController('/v1', TestController());

      final match = app.router.findRoute('GET', '/v1/hello');
      expect(match, isNotNull);

      // Should handle trailing slashes in prefix or path
      app.useController('/v2/', TestController()); // Trailing slash in prefix
      final match2 = app.router.findRoute('GET', '/v2/hello');
      expect(match2, isNotNull);
    });

    test('works with IsolatedContainer', () async {
      final isolated = IsolatedContainer(prefix: '/isolated');

      // This is the key test: useController on IsolatedContainer (BaseContainer)
      isolated.useController('/ctrl', TestController());

      // Verify route registration in the isolated container's router
      final match = isolated.router.findRoute('GET', '/ctrl/hello');
      expect(match, isNotNull);

      // Optional: Verify mounting
      app.mount('/isolated', isolated);

      // When mounted, the parent router delegates.
      // We can't easily test full delegation without full request cycle,
      // but finding it in isolated router confirms registration worked.
    });
  });
}
