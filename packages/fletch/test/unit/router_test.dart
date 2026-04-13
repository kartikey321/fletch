import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

void main() {
  group('RadixRouter matching', () {
    late RadixRouter router;

    setUp(() => router = RadixRouter());

    test('matches static routes first', () {
      void handler(Request _, Response __) {}
      router.addRoute('GET', '/users/list', handler);
      router.addRoute('GET', '/users/:id', (req, res) {});

      final match = router.findRoute('GET', '/users/list');
      expect(match, isNotNull);
      expect(match!.handler, same(handler));
    });

    test('extracts regex constrained parameters', () {
      router.addRoute('GET', '/users/:id(\\d+)', (req, res) {});
      final match = router.findRoute('GET', '/users/42');

      expect(match, isNotNull);
      expect(match!.pathParams['id'], '42');
    });

    test('skips non-matching regex segments', () {
      router.addRoute('GET', '/users/:id(\\d+)', (req, res) {});
      final match = router.findRoute('GET', '/users/abc');

      expect(match, isNull);
    });

    test('supports wildcard parameters', () {
      router.addRoute('GET', '/assets/:file', (req, res) {});
      final match = router.findRoute('GET', '/assets/logo.png');

      expect(match, isNotNull);
      expect(match!.pathParams['file'], 'logo.png');
    });

    test('throws on conflicting handlers', () {
      router.addRoute('GET', '/conflict', (req, res) {});
      expect(
        () => router.addRoute('GET', '/conflict', (req, res) {}),
        throwsA(isA<RouteConflictError>()),
      );
    });

    test('backtracks when regex matches segment but fails deeper', () {
      // /users/:id(\d+)/posts  — regex matches "42" but there is no /posts node
      // /users/:name/info      — plain wildcard, should match /users/42/info
      router.addRoute('GET', r'/users/:id(\d+)/posts', (req, res) {});
      router.addRoute('GET', '/users/:name/info', (req, res) {});

      final match = router.findRoute('GET', '/users/42/info');
      expect(match, isNotNull);
      expect(match!.pathParams['name'], '42');
    });

    test('backtracks wildcard when deeper path fails', () {
      // :slug matches "foo", but /bar is not registered under that branch
      // while /static/foo IS registered
      router.addRoute('GET', '/static/:slug', (req, res) {});
      router.addRoute('GET', '/static/foo', (req, res) {});

      // Should match the static route, not the param route
      final match = router.findRoute('GET', '/static/foo');
      expect(match, isNotNull);
      // Param map should be empty — static wins
      expect(match!.pathParams, isEmpty);
    });

    test('regex node is reused for same pattern, different method', () {
      // Should not throw a RouteConflictError — same node, different method handler
      router.addRoute('GET', r'/items/:id(\d+)', (req, res) {});
      expect(
        () => router.addRoute('POST', r'/items/:id(\d+)', (req, res) {}),
        returnsNormally,
      );
      final match = router.findRoute('POST', '/items/7');
      expect(match, isNotNull);
      expect(match!.pathParams['id'], '7');
    });

    test('invalid named glob segment throws FormatException', () {
      expect(
        () => router.addRoute('GET', '/files/*:123bad', (req, res) {}),
        throwsA(isA<FormatException>()),
      );
    });

    test('delegates to isolated routers at prefixes', () {
      final isolated = RadixRouter();
      void isolatedHandler(Request _, Response __) {}
      isolated.addRoute('GET', '/health', isolatedHandler);

      router.addIsolatedRouter('/api', isolated);

      final match = router.findRoute('GET', '/api/health');
      expect(match, isNotNull);
      expect(match!.handler, same(isolatedHandler));
    });
  });

  group('Optional parameters (:name?)', () {
    late RadixRouter router;
    setUp(() => router = RadixRouter());

    test('matches without the optional segment', () {
      router.addRoute('GET', '/users/:id?', (req, res) {});
      final match = router.findRoute('GET', '/users');
      expect(match, isNotNull);
    });

    test('matches with the optional segment and captures param', () {
      router.addRoute('GET', '/users/:id?', (req, res) {});
      final match = router.findRoute('GET', '/users/42');
      expect(match, isNotNull);
      expect(match!.pathParams['id'], '42');
    });

    test('optional segment in the middle of a path', () {
      router.addRoute('GET', '/api/:version?/users', (req, res) {});

      final withVersion = router.findRoute('GET', '/api/v2/users');
      expect(withVersion, isNotNull);
      expect(withVersion!.pathParams['version'], 'v2');

      final withoutVersion = router.findRoute('GET', '/api/users');
      expect(withoutVersion, isNotNull);
    });

    test('multiple optional segments expand correctly', () {
      router.addRoute('GET', '/a/:x?/:y?', (req, res) {});

      expect(router.findRoute('GET', '/a/1/2'), isNotNull);
      expect(router.findRoute('GET', '/a/1'), isNotNull);
      expect(router.findRoute('GET', '/a'), isNotNull);
    });

    test('optional regex-constrained param', () {
      router.addRoute('GET', '/items/:id(\\d+)?', (req, res) {});

      final withId = router.findRoute('GET', '/items/7');
      expect(withId, isNotNull);
      expect(withId!.pathParams['id'], '7');

      expect(router.findRoute('GET', '/items'), isNotNull);
      expect(router.findRoute('GET', '/items/abc'), isNull);
    });
  });

  group('Named catch-all glob (*:name)', () {
    late RadixRouter router;
    setUp(() => router = RadixRouter());

    test('captures single remaining segment', () {
      router.addRoute('GET', '/files/*:path', (req, res) {});
      final match = router.findRoute('GET', '/files/logo.png');
      expect(match, isNotNull);
      expect(match!.pathParams['path'], 'logo.png');
    });

    test('captures multi-segment remainder', () {
      router.addRoute('GET', '/files/*:path', (req, res) {});
      final match = router.findRoute('GET', '/files/images/2024/photo.jpg');
      expect(match, isNotNull);
      expect(match!.pathParams['path'], 'images/2024/photo.jpg');
    });

    test('unnamed glob still works without capture', () {
      router.addRoute('GET', '/static/*', (req, res) {});
      final match = router.findRoute('GET', '/static/app.js');
      expect(match, isNotNull);
      expect(match!.pathParams, isEmpty);
    });

    test('named glob with prefix params captures both', () {
      router.addRoute('GET', '/users/:id/files/*:rest', (req, res) {});
      final match = router.findRoute('GET', '/users/42/files/docs/report.pdf');
      expect(match, isNotNull);
      expect(match!.pathParams['id'], '42');
      expect(match.pathParams['rest'], 'docs/report.pdf');
    });
  });
}
