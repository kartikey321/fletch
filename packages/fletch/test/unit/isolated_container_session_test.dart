// Regression coverage for two related IsolatedContainer bugs found while
// testing an unrelated request-lifecycle fix:
//
// 1. A session first created via a route mounted through IsolatedContainer
//    never got a Set-Cookie at all -- request-forwarding hardcoded
//    isSessionNew: false regardless of whether the underlying session was
//    actually new. Every request silently started a brand-new,
//    unreachable server-side session.
// 2. IsolatedContainer's secureCookies always defaulted to true,
//    independent of the host app's own setting -- so fixing #1 alone would
//    issue a Secure cookie the browser silently discards over plain HTTP
//    in the standard local-dev setup (`Fletch(secureCookies: false)`).
//    These two are fixed together; #1 is not useful without #2.
//
// NOTE: this branch is cut from main, which does not yet include the
// separate fix/request-lifecycle branch's change making global middleware
// wrap route dispatch (including isolated-container routes). On main,
// global middleware still never runs around isolated-container routes at
// all (they're registered via addIsolatedRouter, not addRoute, so they
// never go through wrapWithMiddleware's global-middleware loop). Once
// both branches are merged, re-check the combined behavior: global
// middleware will start executing around isolated routes, but still won't
// be able to observe exceptions thrown from inside one, because the
// isolated route's own nested processRequest call fully handles and
// swallows them before control returns to the host app's middleware
// chain. That combined-state interaction isn't testable from either
// branch alone and should get its own coverage once merged.

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('IsolatedContainer session cookie issuance', () {
    test(
        'a session first touched via a mounted route issues a cookie the '
        'top-level app can read back', () async {
      final store = MemorySessionStore();
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: store,
        secureCookies: false,
      );
      final sub = IsolatedContainer(prefix: '/v1', secureCookies: false);
      sub.get('/touch', (req, res) {
        req.session['seen'] = 'yes';
        res.text('ok');
      });
      sub.mount(app);
      app.get('/read-top-level', (req, res) {
        res.json({'seen': req.session['seen']});
      });
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      final first = await harness.get('/v1/touch');
      expect(first.statusCode, 200);
      final setCookie = first.headers['set-cookie'];
      expect(setCookie, isNotNull);
      expect(store.sessionCount, 1);

      final second = await harness.get(
        '/read-top-level',
        headers: {'Cookie': setCookie!.split(';').first},
      );
      expect(second.body, contains('"seen":"yes"'));
    });

    test(
        'a session-free mounted route still issues no cookie and writes '
        'nothing to the store', () async {
      final store = MemorySessionStore();
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: store,
        secureCookies: false,
      );
      final sub = IsolatedContainer(prefix: '/v1', secureCookies: false);
      sub.get('/info', (req, res) => res.text('info'));
      sub.mount(app);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      final response = await harness.get('/v1/info');

      expect(response.statusCode, 200);
      expect(response.headers['set-cookie'], isNull);
      expect(store.sessionCount, 0);
    });
  });

  group('IsolatedContainer secureCookies', () {
    test(
        'matching secureCookies: false on both host app and container omits '
        'the Secure attribute', () async {
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: MemorySessionStore(),
        secureCookies: false,
      );
      final sub = IsolatedContainer(prefix: '/v1', secureCookies: false);
      sub.get('/touch', (req, res) {
        req.session['x'] = '1';
        res.text('ok');
      });
      sub.mount(app);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      final response = await harness.get('/v1/touch');
      final setCookie = response.headers['set-cookie']!;
      expect(setCookie.toLowerCase(), isNot(contains('secure')));
    });

    test(
        'an unconfigured IsolatedContainer (default secureCookies: true) '
        'mounted on an insecure host app issues a Secure cookie the '
        'browser would drop over HTTP -- a real, documented footgun this '
        "fix makes configurable rather than silently swallowing (that's "
        'the mismatch mount() now warns about)', () async {
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: MemorySessionStore(),
        secureCookies: false,
      );
      final sub = IsolatedContainer(prefix: '/v1'); // secureCookies defaults true
      sub.get('/touch', (req, res) {
        req.session['x'] = '1';
        res.text('ok');
      });
      sub.mount(app);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      final response = await harness.get('/v1/touch');
      final setCookie = response.headers['set-cookie']!;
      expect(setCookie.toLowerCase(), contains('secure'));
    });
  });
}
