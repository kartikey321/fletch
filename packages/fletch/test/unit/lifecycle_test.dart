import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Request lifecycle', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('global middleware runs for unmatched routes (404s), not just '
        'matched ones', () async {
      final middlewareRanFor = <String>[];

      harness.app.use((req, res, next) async {
        middlewareRanFor.add(req.uri.path);
        await next();
      });

      harness.app.get('/known', (req, res) => res.text('ok'));

      final knownResponse = await harness.get('/known');
      final missingResponse = await harness.get('/does-not-exist');

      expect(knownResponse.statusCode, 200);
      expect(missingResponse.statusCode, 404);
      // Previously, global middleware wrapped only a matched route's
      // handler — an unmatched route threw NotFoundError in processRequest
      // before the middleware chain was ever entered, so this list would
      // only ever contain '/known'. Both requests must reach it now.
      expect(middlewareRanFor, ['/known', '/does-not-exist']);
    });

    test('global middleware wraps thrown handler exceptions', () async {
      final observedErrors = <String>[];

      harness.app.use((req, res, next) async {
        try {
          await next();
        } catch (e) {
          observedErrors.add(e.toString());
          rethrow;
        }
      });

      harness.app.get('/boom', (req, res) {
        throw StateError('boom');
      });

      final response = await harness.get('/boom');

      expect(response.statusCode, 500);
      expect(observedErrors, hasLength(1));
      expect(observedErrors.first, contains('boom'));
    });

    test('session mutations made inside an SSE handler body are persisted',
        () async {
      final store = MemorySessionStore();
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: store,
        secureCookies: false,
      );
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.get('/stream-session', (req, res) async {
        await res.sse((sink) async {
          // Mutating session here only works if it's saved *after* this
          // handler body actually runs. `Response.send()` is what invokes
          // this callback — if session.save() ran before send() (the old
          // ordering bug), this mutation would never reach the store.
          req.session['visited'] = 'yes';
          await sink.sendEvent('done');
          await sink.close();
        });
      });

      app.get('/read-session', (req, res) {
        res.json({'visited': req.session['visited']});
      });

      app.get('/init-session', (req, res) {
        // A plain (non-SSE) touch first, so the session cookie is issued on
        // a normal response — cookies can't be added once an SSE response
        // starts flushing, so a session created *and* first touched inside
        // an SSE handler body would never receive a Set-Cookie on that same
        // response. That's a structural HTTP constraint, not what this test
        // is about: this test only cares whether a mutation made inside an
        // already-established session's SSE handler body reaches the store.
        req.session['init'] = 'yes';
        res.text('ok');
      });

      final init = await harness.get('/init-session');
      expect(init.statusCode, 200);
      final setCookie = init.headers['set-cookie'];
      expect(setCookie, isNotNull);
      final cookieValue = setCookie!.split(';').first;

      final first = await harness.get(
        '/stream-session',
        headers: {'Cookie': cookieValue},
      );
      expect(first.statusCode, 200);

      final second = await harness.get(
        '/read-session',
        headers: {'Cookie': cookieValue},
      );

      expect(second.statusCode, 200);
      expect(second.body, contains('"visited":"yes"'));
    });

    test(
        'a session first touched inside an SSE handler body on a brand-new '
        'session is discarded instead of persisted unreachably', () async {
      final store = MemorySessionStore();
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: store,
        secureCookies: false,
      );
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.get('/stream-session', (req, res) async {
        await res.sse((sink) async {
          // First touch of a brand-new session, happening only once send()
          // is already flushing headers — there's no way to get a
          // Set-Cookie back to the client for this session, so it must not
          // be written to the store either (an unreachable row is a leak).
          req.session['visited'] = 'yes';
          await sink.sendEvent('done');
          await sink.close();
        });
      });

      expect(store.sessionCount, 0);

      final response = await harness.get('/stream-session');

      expect(response.statusCode, 200);
      expect(response.headers['set-cookie'], isNull);
      expect(store.sessionCount, 0);
    });

    test('an exception thrown inside a streaming handler body does not '
        'crash the server or leave it unresponsive', () async {
      harness.app.get('/stream-throws', (req, res) async {
        await res.stream(
          (() async* {
            yield [1, 2, 3];
            throw StateError('stream failed mid-flight');
          })(),
        );
      });
      harness.app.get('/still-alive', (req, res) => res.text('ok'));

      // The streaming response will likely error client-side (truncated
      // body) — that's expected and not what's under test. What matters is
      // that the exception is caught by the framework instead of escaping
      // uncaught, and that the server keeps serving subsequent requests.
      try {
        await harness.get('/stream-throws');
      } catch (_) {
        // Client-side read failure on a truncated stream is fine.
      }

      final response = await harness.get('/still-alive');
      expect(response.statusCode, 200);
      expect(response.body, 'ok');
    });
  });
}
