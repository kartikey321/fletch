import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('ListRouter — HTTP integration', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness(app: Fletch(router: ListRouter())));
    tearDown(() => harness.dispose());

    test('matches static GET route', () async {
      harness.app.get('/hello', (req, res) => res.text('world'));
      final r = await harness.get('/hello');
      expect(r.statusCode, 200);
      expect(r.body, 'world');
    });

    test('matches static POST route', () async {
      harness.app.post('/submit', (req, res) => res.json({'ok': true}));
      final r = await harness.post('/submit');
      expect(r.statusCode, 200);
      expect(r.body, contains('"ok":true'));
    });

    test('extracts single path parameter', () async {
      harness.app.get('/users/:id', (req, res) {
        res.text(req.params['id']!);
      });
      final r = await harness.get('/users/42');
      expect(r.statusCode, 200);
      expect(r.body, '42');
    });

    test('extracts multiple path parameters', () async {
      harness.app.get('/orgs/:org/repos/:repo', (req, res) {
        res.json({'org': req.params['org'], 'repo': req.params['repo']});
      });
      final r = await harness.get('/orgs/dart/repos/fletch');
      expect(r.statusCode, 200);
      expect(r.body, contains('"org":"dart"'));
      expect(r.body, contains('"repo":"fletch"'));
    });

    test('returns 404 for unknown path', () async {
      final r = await harness.get('/not-found');
      expect(r.statusCode, 404);
    });

    test('method mismatch returns 404', () async {
      harness.app.get('/only-get', (req, res) => res.text('ok'));
      final r = await harness.send('POST', '/only-get');
      expect(r.statusCode, 404);
    });

    test('multiple routes coexist and resolve correctly', () async {
      harness.app.get('/a', (req, res) => res.text('a'));
      harness.app.get('/b', (req, res) => res.text('b'));
      harness.app.get('/c', (req, res) => res.text('c'));

      expect((await harness.get('/a')).body, 'a');
      expect((await harness.get('/b')).body, 'b');
      expect((await harness.get('/c')).body, 'c');
    });

    test('supports mounted IsolatedContainer', () async {
      final sub = IsolatedContainer(prefix: '/sub');
      sub.get('/ping', (req, res) => res.text('pong'));
      sub.mount(harness.app);

      final r = await harness.get('/sub/ping');
      expect(r.statusCode, 200);
      expect(r.body, 'pong');
    });

    test('does not overmatch isolated router prefix boundaries', () async {
      final sub = IsolatedContainer(prefix: '/api');
      sub.get('/status', (req, res) => res.text('isolated'));
      sub.mount(harness.app);

      harness.app.get('/apix/status', (req, res) => res.text('main'));

      final r = await harness.get('/apix/status');
      expect(r.statusCode, 200);
      expect(r.body, 'main');
    });
  });

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

    test('routes no-param match reuses shared empty pathParams map', () {
      final router = ListRouter();
      router.addRoute('GET', '/static', (req, res) {});

      final m1 = router.findRoute('GET', '/static');
      final m2 = router.findRoute('GET', '/static');
      expect(m1, isNotNull);
      expect(m2, isNotNull);
      // Both should use the same const empty map
      expect(identical(m1!.pathParams, m2!.pathParams), isTrue);
    });
  });
}
