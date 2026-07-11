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

    test(
        'a slow SSE route mounted via IsolatedContainer still completes '
        'successfully despite a short requestTimeout, instead of a '
        'false-positive 408', () async {
      // A mounted route's "handler" (from dispatchTimeout's perspective) is
      // a full nested processRequest call, including its own send() — for
      // an SSE route, response.isSent flips true almost immediately (SSE
      // setup is fast), long before the timeout fires. Without the
      // response.isSent check in processRequest's onTimeout callback, that
      // combination used to produce a spurious "Error after response flush
      // began ... 408 Request Timeout" log for a request that was actually
      // completing normally.
      final app = Fletch(
        requestTimeout: const Duration(milliseconds: 40),
        secureCookies: false,
      );
      final sub = IsolatedContainer(prefix: '/v1');
      sub.get('/events', (req, res) async {
        await res.sse((sink) async {
          for (var i = 0; i < 3; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await sink.sendEvent('tick-$i');
          }
          await sink.close();
        });
      });
      sub.mount(app);
      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      // Total stream time (~90ms) exceeds requestTimeout (40ms).
      final response = await harness.get('/v1/events');
      expect(response.statusCode, 200);
      expect(response.body, contains('tick-0'));
      expect(response.body, contains('tick-1'));
      expect(response.body, contains('tick-2'));
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

  group('session.regenerate() inside a streaming handler body', () {
    test(
        'destroys the previous session with no way to recover it — real '
        'data loss, not a harmless discard (documented, not fixed: '
        'regenerate() must destroy the old id immediately for its own '
        'session-fixation defense to mean anything)', () async {
      final store = MemorySessionStore();
      final app = Fletch(
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
      app.get('/stream-regen', (req, res) async {
        await res.sse((sink) async {
          // Called from inside an SSE body: _applySessionCookie's pre-send
          // check already ran and saw wasRegenerated == false, so no
          // Set-Cookie for the new id can ever be issued — but regenerate()
          // has already destroyed the *old* id's store record by the time
          // this line returns.
          await req.session.regenerate();
          req.session['after'] = 'yes';
          await sink.sendEvent('done');
          await sink.close();
        });
      });
      app.get('/read', (req, res) {
        res.json({'before': req.session['before']});
      });

      final init = await harness.get('/init');
      final cookie = init.headers['set-cookie']!.split(';').first;
      expect(store.sessionCount, 1);

      final streamed = await harness.get(
        '/stream-regen',
        headers: {'Cookie': cookie},
      );
      expect(streamed.statusCode, 200);
      // No new cookie could be issued for the regenerated id.
      expect(streamed.headers['set-cookie'], isNull);

      // The old session (with 'before') is gone -- regenerate() already
      // destroyed it -- and the new one was discarded as unreachable, so
      // the store ends up empty. This is the data-loss finding: fixing it
      // would mean deferring regenerate()'s destroy, which would weaken
      // the session-fixation defense it exists to provide.
      expect(store.sessionCount, 0);

      final readWithOldCookie = await harness.get(
        '/read',
        headers: {'Cookie': cookie},
      );
      expect(readWithOldCookie.body, contains('"before":null'));
    });
  });

  group('reassemble() middleware snapshot', () {
    test(
        'a request paused mid-chain sees a consistent middleware list for '
        'its own lifetime even if a reload cycle runs concurrently, instead '
        'of resuming into a cleared/repopulated list', () async {
      // Exercises clearMiddleware() + re-registration directly (what
      // reassemble() does internally) rather than through
      // hotReload()/reassemble() themselves — Fletch.hotReload() registers
      // a process-wide VM service extension with no duplicate-registration
      // guard, and another test in this suite already calls it once; a
      // second call in the same isolate would throw. The snapshot fix under
      // test lives in _dispatchThroughGlobalMiddleware and doesn't care how
      // clearMiddleware() got invoked.
      final app = Fletch(secureCookies: false);
      final resumeSignal = Completer<void>();
      final secondMiddlewareRan = <String>[];

      app.use((req, res, next) async {
        secondMiddlewareRan.add('first-cycle-a');
        await resumeSignal.future; // pauses mid-chain
        await next();
        secondMiddlewareRan.add('first-cycle-a-after-next');
      });
      app.use((req, res, next) async {
        secondMiddlewareRan.add('first-cycle-b');
        await next();
      });
      app.get('/ping', (req, res) => res.text('ok'));

      final harness = TestServerHarness(app: app);
      addTearDown(harness.dispose);

      // Start a request; it pauses inside the first middleware, having
      // already snapshotted the (2-middleware) list for this dispatch.
      final inFlight = harness.get('/ping');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Simulate a reload cycle running concurrently: clears + replaces
      // global middleware while the request above is still paused.
      app.router.clear();
      app.clearMiddleware();
      app.get('/ping', (req, res) => res.text('ok'));
      app.use((req, res, next) async {
        secondMiddlewareRan.add('second-cycle');
        await next();
      });

      resumeSignal.complete();
      final response = await inFlight;

      expect(response.statusCode, 200);
      // The in-flight request's own snapshot ran both original-cycle
      // middlewares (and only those) to completion, unaffected by the
      // concurrent clear + re-registration.
      expect(secondMiddlewareRan, [
        'first-cycle-a',
        'first-cycle-b',
        'first-cycle-a-after-next',
      ]);

      // A fresh request after the swap sees only the new cycle's
      // middleware.
      secondMiddlewareRan.clear();
      await harness.get('/ping');
      expect(secondMiddlewareRan, ['second-cycle']);
    });
  });
}
