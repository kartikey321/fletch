import 'package:fletch/fletch.dart';
import 'package:fletch_roux_router/fletch_roux_router.dart';
import 'package:test/test.dart';

void main() {
  group('RouxRouter', () {
    late RouxRouter router;
    setUp(() => router = RouxRouter());

    test('static routes', () {
      router.addRoute('GET', '/health', (_, __) {});
      router.addRoute('GET', '/users', (_, __) {});
      expect(router.findRoute('GET', '/health'), isNotNull);
      expect(router.findRoute('GET', '/users'), isNotNull);
      expect(router.findRoute('GET', '/missing'), isNull);
    });

    test('named params', () {
      router.addRoute('GET', '/users/:id', (_, __) {});
      final m = router.findRoute('GET', '/users/42');
      expect(m, isNotNull);
      expect(m!.pathParams['id'], '42');
    });

    test('optional param /:id?', () {
      router.addRoute('GET', '/users/:id?', (_, __) {});
      expect(router.findRoute('GET', '/users'), isNotNull);
      final m = router.findRoute('GET', '/users/42');
      expect(m, isNotNull);
      expect(m!.pathParams['id'], '42');
    });

    test('one-or-more /:path+', () {
      router.addRoute('GET', '/files/:path+', (_, __) {});
      expect(router.findRoute('GET', '/files/a/b/c'), isNotNull);
      expect(router.findRoute('GET', '/files/logo.png'), isNotNull);
      // zero segments should not match +
      expect(router.findRoute('GET', '/files'), isNull);
    });

    test('optional suffix /book{s}?', () {
      router.addRoute('GET', '/book{s}?', (_, __) {});
      expect(router.findRoute('GET', '/book'), isNotNull);
      expect(router.findRoute('GET', '/books'), isNotNull);
    });

    test('method isolation', () {
      router.addRoute('GET', '/ping', (_, __) {});
      expect(router.findRoute('GET', '/ping'), isNotNull);
      expect(router.findRoute('POST', '/ping'), isNull);
    });

    test('clear() removes all routes', () {
      router.addRoute('GET', '/ping', (_, __) {});
      router.clear();
      expect(router.findRoute('GET', '/ping'), isNull);
    });

    test('addIsolatedRouter delegates by prefix', () {
      final sub = RouxRouter();
      sub.addRoute('GET', '/status', (_, __) {});
      router.addIsolatedRouter('/api', sub);

      final m = router.findRoute('GET', '/api/status');
      expect(m, isNotNull);
      // Should not match without prefix
      expect(router.findRoute('GET', '/status'), isNull);
    });

    test('normalizes mount prefix without leading slash', () {
      final sub = RouxRouter()..addRoute('GET', '/status', (_, __) {});
      router.addIsolatedRouter('api', sub);

      expect(router.findRoute('GET', '/api/status'), isNotNull);
    });

    test('normalizes mount prefix with trailing slash', () {
      final sub = RouxRouter()..addRoute('GET', '/status', (_, __) {});
      router.addIsolatedRouter('/api/', sub);

      expect(router.findRoute('GET', '/api/status'), isNotNull);
    });

    test('root mount prefix "/" delegates root paths', () {
      final sub = RouxRouter()..addRoute('GET', '/status', (_, __) {});
      router.addIsolatedRouter('/', sub);

      expect(router.findRoute('GET', '/status'), isNotNull);
    });

    test('duplicate mount prefix throws RouteConflictError', () {
      router.addIsolatedRouter('/api', RouxRouter());

      expect(
        () => router.addIsolatedRouter('/api/', RouxRouter()),
        throwsA(isA<RouteConflictError>()),
      );
    });

    test('isolated router prefix boundary prevents false match', () {
      final sub = RouxRouter();
      sub.addRoute('GET', '/x', (_, __) {});
      router.addIsolatedRouter('/api', sub);
      // /apiv2/x should NOT delegate to the /api sub-router
      expect(router.findRoute('GET', '/apiv2/x'), isNull);
    });

    test('longer prefix wins over shorter', () {
      void shortHandler(_, __) {}
      void longHandler(_, __) {}

      final subShort = RouxRouter()..addRoute('GET', '/x', shortHandler);
      final subLong = RouxRouter()..addRoute('GET', '/x', longHandler);
      router.addIsolatedRouter('/a', subShort);
      router.addIsolatedRouter('/a/b', subLong);

      // /a/b/x should match the longer /a/b mount
      final m = router.findRoute('GET', '/a/b/x');
      expect(m, isNotNull);
      expect(m!.handler, same(longHandler));
    });

    test('clear() removes both routes and isolated mounts', () {
      final sub = RouxRouter()..addRoute('GET', '/status', (_, __) {});
      router.addRoute('GET', '/ping', (_, __) {});
      router.addIsolatedRouter('/api', sub);

      expect(router.findRoute('GET', '/ping'), isNotNull);
      expect(router.findRoute('GET', '/api/status'), isNotNull);

      router.clear();

      expect(router.findRoute('GET', '/ping'), isNull);
      expect(router.findRoute('GET', '/api/status'), isNull);
    });

    test('case-sensitive matching', () {
      router.addRoute('GET', '/Users', (_, __) {});

      expect(router.findRoute('GET', '/Users'), isNotNull);
      expect(router.findRoute('GET', '/users'), isNull);
    });
  });
}
