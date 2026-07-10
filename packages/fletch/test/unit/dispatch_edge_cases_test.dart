// Structured regression coverage for edge cases surfaced by an independent
// adversarial review of the request-lifecycle fix in base_container.dart /
// fletch.dart. Grouped by the specific behavior each concern is about.
//
// Two of these groups ("known limitation") intentionally lock in *current*,
// documented-but-imperfect behavior rather than asserting the ideal — see
// the doc comment on BaseContainer.processRequest for why fixing them isn't
// free (it trades off against dispatchTimeout not truncating streams). If
// that tradeoff is ever revisited, these tests are meant to be the first
// thing that needs updating, not a silent behavior change nobody notices.

import 'dart:async';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('dispatchTimeout scoping', () {
    test(
        'a slow response flush survives a short requestTimeout — only '
        'dispatch (routing + middleware + handler) is bounded, not send()',
        () async {
      final app = Fletch(
        requestTimeout: const Duration(milliseconds: 50),
        secureCookies: false,
      );
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.get('/slow-stream', (req, res) async {
        await res.stream(
          (() async* {
            for (var i = 0; i < 3; i++) {
              await Future.delayed(const Duration(milliseconds: 40));
              yield [i];
            }
          })(),
          flushEachChunk: true,
        );
      });

      final response = await harness.get('/slow-stream');
      // Total stream time (~120ms) exceeds requestTimeout (50ms). If
      // dispatchTimeout bounded the flush too, this would be a 408 with a
      // truncated/empty body instead.
      expect(response.statusCode, 200);
      expect(response.bodyBytes, [0, 1, 2]);
    });

    test(
        'an abandoned dispatch that resumes after its 408 was already sent '
        'does not crash the server or break later requests', () async {
      final resumeSignal = Completer<void>();
      final app = Fletch(
        requestTimeout: const Duration(milliseconds: 30),
        secureCookies: false,
      );
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.get('/hangs', (req, res) async {
        // Future.timeout() cannot cancel this — it keeps running in the
        // background after the 408 is sent, exactly like the orphaned
        // continuation documented on processRequest's doc comment.
        await resumeSignal.future;
        res.text('too late');
      });
      app.get('/still-alive', (req, res) => res.text('ok'));

      final response = await harness.get('/hangs');
      expect(response.statusCode, 408);

      resumeSignal.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final followUp = await harness.get('/still-alive');
      expect(followUp.statusCode, 200);
      expect(followUp.body, 'ok');
    });

    test(
        'a session mutation made by an abandoned dispatch after its 408 '
        'session-save already ran is not persisted (documented data loss, '
        'not a crash)', () async {
      final store = MemorySessionStore();
      final resumeSignal = Completer<void>();
      final app = Fletch(
        requestTimeout: const Duration(milliseconds: 30),
        sessionSecret: 'a' * 32,
        sessionStore: store,
        secureCookies: false,
      );
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.get('/init', (req, res) {
        req.session['before'] = 'yes';
        res.text('ok');
      });
      app.get('/hangs', (req, res) async {
        await resumeSignal.future;
        // This mutation happens after the timeout's finally already called
        // session.save() — there is no second save, so it's lost.
        req.session['late'] = 'yes';
        res.text('too late');
      });
      app.get('/read', (req, res) {
        res.json({
          'before': req.session['before'],
          'late': req.session['late'],
        });
      });

      final init = await harness.get('/init');
      final cookie = init.headers['set-cookie']!.split(';').first;

      final timedOut = await harness.get(
        '/hangs',
        headers: {'Cookie': cookie},
      );
      expect(timedOut.statusCode, 408);

      resumeSignal.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final read = await harness.get('/read', headers: {'Cookie': cookie});
      expect(read.body, contains('"before":"yes"'));
      expect(read.body, contains('"late":null'));
    });
  });

  group('KNOWN LIMITATION: global middleware does not observe the response '
      'flush', () {
    test("middleware's post-next() code runs before an SSE handler body "
        'executes, not after', () async {
      final order = <String>[];
      final app = Fletch(secureCookies: false);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.use((req, res, next) async {
        await next();
        order.add('middleware-after-next');
      });

      app.get('/events', (req, res) async {
        await res.sse((sink) async {
          order.add('sse-body');
          await sink.sendEvent('done');
          await sink.close();
        });
      });

      await harness.get('/events');

      // Were middleware genuinely wrapping the flush, this would read
      // ['sse-body', 'middleware-after-next'].
      expect(order, ['middleware-after-next', 'sse-body']);
    });

    test('an exception thrown inside an SSE handler body is not observable '
        "by global middleware's try/catch around next()", () async {
      final observedByMiddleware = <String>[];
      final app = Fletch(secureCookies: false);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      app.use((req, res, next) async {
        try {
          await next();
        } catch (e) {
          observedByMiddleware.add(e.toString());
          rethrow;
        }
      });

      app.get('/events-throws', (req, res) async {
        await res.sse((sink) async {
          throw StateError('boom-in-sse-body');
        });
      });

      try {
        await harness.get('/events-throws');
      } catch (_) {
        // Client-side read failure on a response that errored mid-flight
        // is expected and not what's under test.
      }

      // processRequest's own outer catch still handles this (logged, not
      // left uncaught — see lifecycle_test.dart's streaming-throws
      // coverage), but middleware-level observability doesn't extend into
      // the flush.
      expect(observedByMiddleware, isEmpty);
    });
  });

  group('IsolatedContainer + session interaction', () {
    test(
        'a session-free isolated-container route does not log a spurious '
        'warning or write anything to the session store', () async {
      final store = MemorySessionStore();
      final app = Fletch(
        sessionSecret: 'a' * 32,
        sessionStore: store,
        secureCookies: false,
      );
      final sub = IsolatedContainer(prefix: '/v1');
      sub.get('/info', (req, res) => res.text('info'));
      sub.mount(app);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      final response = await harness.get('/v1/info');

      expect(response.statusCode, 200);
      expect(response.body, 'info');
      // IsolatedContainer's routing delegate reads request.session.id
      // internally for every mounted request (see
      // isolated_container.dart's _IsolatedRouterDelegate), which flips
      // sessionTouched even though this handler never uses sessions.
      // Nothing was actually mutated, so no cookie should be issued and
      // nothing should reach the store.
      expect(response.headers['set-cookie'], isNull);
      expect(store.sessionCount, 0);
    });

    // A companion test for a session-using isolated-container route (one
    // that actually sets session data and expects a usable cookie back)
    // deliberately isn't here: it surfaces a separate, pre-existing bug in
    // IsolatedContainer's request-forwarding (isSessionNew is hardcoded to
    // false, so a session first created via a mounted route never gets a
    // Set-Cookie at all) that's out of scope for this branch — tracked
    // separately, not fixed here.
  });
}
