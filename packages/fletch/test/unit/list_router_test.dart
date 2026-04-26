import 'package:fletch/fletch.dart';
import 'package:test/test.dart';
void main() {
  group('ListRouter — unit (no server)', () {
    test('findRoute returns null for unregistered path', () {
      final router = ListRouter();
      final match = router.findRoute('GET', '/missing');
      expect(match, isNull);
    });

    test('findRoute returns handler for registered static route', () {
      final router = ListRouter();
      void handler(Request r, Response s) {}
      router.addRoute('GET', '/test', handler);

      final match = router.findRoute('GET', '/test');
      expect(match, isNotNull);
      expect(match!.handler, same(handler));
    });

    test('findRoute extracts params and returns them in RouteMatch', () {
      final router = ListRouter();
      router.addRoute('GET', '/items/:id', (req, res) {});

      final match = router.findRoute('GET', '/items/99');
      expect(match, isNotNull);
      expect(match!.pathParams['id'], '99');
    });

    test('clear() removes all registered routes', () {
      final router = ListRouter();
      router.addRoute('GET', '/exists', (req, res) {});
      router.clear();

      final match = router.findRoute('GET', '/exists');
      expect(match, isNull);
    });

    test('throws RouteConflictError on duplicate isolated router prefix', () {
      final router = ListRouter();
      final sub = ListRouter();
      router.addIsolatedRouter('/api', sub);

      expect(
        () => router.addIsolatedRouter('/api', ListRouter()),
        throwsA(isA<RouteConflictError>()),
      );
    });

    test('routes with no params return empty pathParams maps', () {
      final router = ListRouter();
      router.addRoute('GET', '/static', (req, res) {});

      final m1 = router.findRoute('GET', '/static');
      final m2 = router.findRoute('GET', '/static');
      expect(m1, isNotNull);
      expect(m2, isNotNull);
      expect(m1!.pathParams, isEmpty);
      expect(m2!.pathParams, isEmpty);
    });

    test('static routes support optional trailing slash', () {
      final router = ListRouter();
      router.addRoute('GET', '/hello', (req, res) {});

      expect(router.findRoute('GET', '/hello'), isNotNull);
      expect(router.findRoute('GET', '/hello/'), isNotNull);
    });

    test(
        'regex-constrained params match valid values and reject invalid values',
        () {
      final router = ListRouter();
      router.addRoute('GET', '/users/:id(\\d+)', (req, res) {});

      final ok = router.findRoute('GET', '/users/123');
      final bad = router.findRoute('GET', '/users/abc');

      expect(ok, isNotNull);
      expect(ok!.pathParams['id'], '123');
      expect(bad, isNull);
    });

    test('supports underscore in param names after first character', () {
      final router = ListRouter();
      router.addRoute('GET', '/flags/:internal_flag', (req, res) {});

      final match = router.findRoute('GET', '/flags/enabled');
      expect(match, isNotNull);
      expect(match!.pathParams['internal_flag'], 'enabled');
    });

    test('isolated prefix "/" catches root paths', () {
      final parent = ListRouter();
      final isolated = ListRouter();
      void isolatedHandler(Request _, Response __) {}
      isolated.addRoute('GET', '/health', isolatedHandler);

      parent.addIsolatedRouter('/', isolated);

      final match = parent.findRoute('GET', '/health');
      expect(match, isNotNull);
      expect(match!.handler, same(isolatedHandler));
    });

    test('isolated router receives empty path when request equals prefix', () {
      final parent = ListRouter();
      final isolated = ListRouter();
      void rootHandler(Request _, Response __) {}
      isolated.addRoute('GET', '', rootHandler);

      parent.addIsolatedRouter('/api', isolated);

      final match = parent.findRoute('GET', '/api');
      expect(match, isNotNull);
      expect(match!.handler, same(rootHandler));
    });

    test('clear() removes regular and isolated routes', () {
      final parent = ListRouter();
      final isolated = ListRouter();

      parent.addRoute('GET', '/main', (req, res) {});
      isolated.addRoute('GET', '/health', (req, res) {});
      parent.addIsolatedRouter('/api', isolated);

      expect(parent.findRoute('GET', '/main'), isNotNull);
      expect(parent.findRoute('GET', '/api/health'), isNotNull);

      parent.clear();

      expect(parent.findRoute('GET', '/main'), isNull);
      expect(parent.findRoute('GET', '/api/health'), isNull);
    });

    test('isolated router does not overmatch similar prefixes', () {
      final parent = ListRouter();
      final isolated = ListRouter();
      isolated.addRoute('GET', '/status', (req, res) {});
      parent.addIsolatedRouter('/api', isolated);

      expect(parent.findRoute('GET', '/apix/status'), isNull);
    });
  });
}
