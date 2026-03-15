import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:fletch/src/middleware/cookies_parser.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  // ────────────────────────────────────────────────────────────────────────
  // DIContainer — internal DI class
  // ────────────────────────────────────────────────────────────────────────

  group('DIContainer', () {
    test('registerSingleton and get returns same instance', () {
      final c = DIContainer();
      c.registerSingleton<String>('hello');
      expect(c.get<String>(), 'hello');
    });

    test('registerFactory creates and caches instance on first get', () {
      final c = DIContainer();
      var count = 0;
      c.registerFactory<int>(() => ++count);
      final first = c.get<int>();
      final second = c.get<int>(); // cached
      expect(first, 1);
      expect(second, 1); // same cached value
    });

    test('get throws when type not registered', () {
      final c = DIContainer();
      expect(() => c.get<String>(), throwsA(isA<Exception>()));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // SessionStore default no-op implementations
  // ────────────────────────────────────────────────────────────────────────

  group('SessionStore default implementations', () {
    late _MinimalSessionStore store;

    setUp(() => store = _MinimalSessionStore());

    test('touch() is a no-op by default', () async {
      await expectLater(store.touch('any-id'), completes);
    });

    test('cleanup() is a no-op by default', () async {
      await expectLater(store.cleanup(), completes);
    });

    test('dispose() is a no-op by default', () async {
      await expectLater(store.dispose(), completes);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // MemorySessionStore — touch / sessionCount / expiredSessionCount
  // ────────────────────────────────────────────────────────────────────────

  group('MemorySessionStore extended API', () {
    test('touch() extends expiry for existing session', () async {
      final store = MemorySessionStore();
      await store.save('s1', {'x': 1});
      await store.touch('s1', ttl: const Duration(hours: 1));
      final loaded = await store.load('s1');
      expect(loaded, {'x': 1});
      await store.dispose();
    });

    test('touch() on unknown id is a no-op', () async {
      final store = MemorySessionStore();
      await expectLater(store.touch('ghost'), completes);
      await store.dispose();
    });

    test('sessionCount reflects active sessions', () async {
      final store = MemorySessionStore();
      expect(store.sessionCount, 0);
      await store.save('s1', {});
      expect(store.sessionCount, 1);
      await store.dispose();
    });

    test('expiredSessionCount reflects expired but unclean entries', () async {
      final store = MemorySessionStore(
        defaultTTL: const Duration(milliseconds: 10),
      );
      await store.save('s1', {});
      expect(store.expiredSessionCount, 0);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(store.expiredSessionCount, 1);
      await store.dispose();
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Middleware model constructor
  // ────────────────────────────────────────────────────────────────────────

  group('Middleware model', () {
    test('Middleware constructor sets path and handler', () {
      Future<void> handler(Request req, Response res, NextFunction next) async {}
      final m = Middleware('/test', handler);
      expect(m.path, '/test');
      expect(m.handler, same(handler));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Fletch validateConfig — additional error cases
  // ────────────────────────────────────────────────────────────────────────

  group('Fletch validateConfig', () {
    test('maxFileSize <= 0 throws ArgumentError', () {
      expect(() => Fletch(maxFileSize: 0), throwsA(isA<ArgumentError>()));
    });

    test('maxBodySize <= 0 throws ArgumentError', () {
      expect(() => Fletch(maxBodySize: 0), throwsA(isA<ArgumentError>()));
    });

    test('shutdownTimeout of zero throws ArgumentError', () {
      expect(
        () => Fletch(shutdownTimeout: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // BaseContainer async DI methods
  // ────────────────────────────────────────────────────────────────────────

  group('BaseContainer async DI', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('registerSingletonAsync makes instance available after ready', () async {
      harness.app.registerSingletonAsync<_AsyncValue>(
        () async => _AsyncValue('loaded'),
      );
      await harness.app.container.allReady();
      final v = harness.app.container.get<_AsyncValue>();
      expect(v.value, 'loaded');
    });

    test('registerFactoryAsync registers an async factory', () async {
      harness.app.registerFactoryAsync<_AsyncValue>(
        () async => _AsyncValue('factory'),
      );
      final v = await harness.app.container.getAsync<_AsyncValue>();
      expect(v.value, 'factory');
    });

    test('registerLazySingletonAsync registers a lazy async singleton', () async {
      harness.app.registerLazySingletonAsync<_AsyncLazy>(
        () async => _AsyncLazy(),
      );
      // Lazy singletons are resolved on demand — use getAsync() to trigger the
      // factory and wait for it, then get() works for subsequent synced calls.
      final v = await harness.app.container.getAsync<_AsyncLazy>();
      expect(v, isNotNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Request — query getter, empty body, text body
  // ────────────────────────────────────────────────────────────────────────

  group('Request body parsing edge cases', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('query getter returns query parameters', () async {
      harness.app.get('/search', (req, res) {
        res.json({'q': req.query['q'], 'page': req.query['page']});
      });
      final r = await harness.get('/search?q=dart&page=2');
      expect(r.statusCode, 200);
      expect(r.body, contains('"q":"dart"'));
      expect(r.body, contains('"page":"2"'));
    });

    test('empty POST body returns null from req.body', () async {
      harness.app.post('/empty', (req, res) async {
        final b = await req.body;
        res.json({'isNull': b == null});
      });
      final r = await harness.post('/empty', body: '');
      expect(r.statusCode, 200);
      expect(r.body, contains('"isNull":true'));
    });

    test('text/plain body returns string from req.body', () async {
      harness.app.post('/text', (req, res) async {
        final b = await req.body as String;
        res.json({'body': b});
      });
      final r = await harness.send('POST', '/text',
          body: 'hello world',
          headers: {'Content-Type': 'text/plain; charset=utf-8'});
      expect(r.statusCode, 200);
      expect(r.body, contains('"body":"hello world"'));
    });

    test('formData cached on second access', () async {
      harness.app.post('/fd', (req, res) async {
        final fd1 = await req.formData;
        final fd2 = await req.formData; // hits cache
        res.json({'same': identical(fd1, fd2)});
      });
      final r = await harness.post('/fd',
          body: 'foo=bar',
          headers: {'Content-Type': 'application/x-www-form-urlencoded'});
      expect(r.statusCode, 200);
      expect(r.body, contains('"same":true'));
    });

    test('formData on non-multipart request returns empty map', () async {
      harness.app.post('/fd-empty', (req, res) async {
        final fd = await req.formData;
        res.json({'empty': fd.isEmpty});
      });
      final r = await harness.post('/fd-empty',
          body: '{"x":1}',
          headers: {'Content-Type': 'application/json'});
      expect(r.statusCode, 200);
      expect(r.body, contains('"empty":true'));
    });

    test('formData with multipart but no boundary returns empty', () async {
      harness.app.post('/fd-no-boundary', (req, res) async {
        final fd = await req.formData;
        res.json({'empty': fd.isEmpty});
      });
      final r = await harness.send('POST', '/fd-no-boundary',
          body: 'some body',
          headers: {'Content-Type': 'multipart/form-data'});
      expect(r.statusCode, 200);
      expect(r.body, contains('"empty":true'));
    });

    test('req.files getter returns multipart files', () async {
      await harness.start();
      harness.app.post('/files', (req, res) async {
        final files = await req.files;
        res.json({'count': files.length});
      });
      final request = http.MultipartRequest('POST', harness.uri('/files'))
        ..files.add(http.MultipartFile.fromBytes(
          'f',
          [1, 2, 3],
          filename: 'test.bin',
        ));
      final streamed = await harness.sendMultipart(request);
      final r = await http.Response.fromStream(streamed);
      expect(r.statusCode, 200);
      expect(r.body, contains('"count":1'));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Session operations
  // ────────────────────────────────────────────────────────────────────────

  group('Session operations', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('session.remove() removes a key', () async {
      harness.app.get('/remove', (req, res) {
        req.session['a'] = 'val';
        req.session.remove('a');
        res.json({'has': req.session['a'] != null});
      });
      final r = await harness.get('/remove');
      expect(r.body, contains('"has":false'));
    });

    test('session.data returns unmodifiable snapshot', () async {
      harness.app.get('/data', (req, res) {
        req.session['k'] = 'v';
        final data = req.session.data;
        res.json({'k': data['k']});
      });
      final r = await harness.get('/data');
      expect(r.body, contains('"k":"v"'));
    });

    test('session.isDirty is true after mutation', () async {
      harness.app.get('/dirty', (req, res) {
        req.session['x'] = 1;
        res.json({'dirty': req.session.isDirty});
      });
      final r = await harness.get('/dirty');
      expect(r.body, contains('"dirty":true'));
    });

    test('session cookie signer verification failure starts fresh session', () async {
      final secret = 'a' * 32;
      final harness2 = TestServerHarness(
        app: Fletch(sessionSecret: secret, secureCookies: false),
      );
      harness2.app.get('/verify', (req, res) {
        final isNew = req.isNewSession;
        res.json({'new': isNew});
      });
      // Send a tampered / invalid session cookie
      final r = await harness2.get('/verify',
          headers: {'Cookie': '${Request.sessionCookieName}=invalid.tampered'});
      expect(r.statusCode, 200);
      expect(r.body, contains('"new":true'));
      await harness2.dispose();
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // CORS — method not allowed (405)
  // ────────────────────────────────────────────────────────────────────────

  group('CORS method not allowed', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('request without Origin and disallowed method returns 405', () async {
      harness.app.use(harness.app.cors(
        allowedMethods: ['GET', 'POST'],
      ));
      harness.app.delete('/api', (req, res) => res.text('ok'));

      // No Origin header + DELETE method (not in allowedMethods)
      final r = await harness.send('DELETE', '/api');
      expect(r.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // RadixRouter — regex and wildcard nodes
  // ────────────────────────────────────────────────────────────────────────

  group('RadixRouter — regex / wildcard', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('path param with custom regex constraint matches', () async {
      harness.app.get(r'/items/:id(\d+)', (req, res) {
        res.text(req.params['id']!);
      });
      final r = await harness.get('/items/42');
      expect(r.statusCode, 200);
      expect(r.body, '42');
    });

    test('path param with custom regex does not match non-digits', () async {
      harness.app.get(r'/items/:id(\d+)', (req, res) => res.text('ok'));
      final r = await harness.get('/items/abc');
      expect(r.statusCode, 404);
    });

    test('wildcard segment matches any path segment', () async {
      harness.app.get('/files/*', (req, res) => res.text('found'));
      final r = await harness.get('/files/a/b/c');
      expect(r.statusCode, 200);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // ListRouter — regex-constrained params (lines 16-17 in route_entry.dart)
  // ────────────────────────────────────────────────────────────────────────

  group('ListRouter — regex-constrained params', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness(app: Fletch(router: ListRouter())));
    tearDown(() => harness.dispose());

    test('path param with custom regex constraint', () async {
      harness.app.get(r'/orders/:id(\d+)', (req, res) {
        res.text(req.params['id']!);
      });
      final r = await harness.get('/orders/99');
      expect(r.statusCode, 200);
      expect(r.body, '99');
    });

    test('regex constraint rejects non-matching segment', () async {
      harness.app.get(r'/orders/:id(\d+)', (req, res) => res.text('ok'));
      final r = await harness.get('/orders/abc');
      expect(r.statusCode, 404);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // CookieParser — empty cookie value skip
  // ────────────────────────────────────────────────────────────────────────

  group('CookieParser empty value', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('cookie with empty value is skipped when allowEmpty is false', () async {
      // Install the CookieParser middleware with allowEmptyValues: false
      harness.app.use(CookieParser.middleware(allowEmptyValues: false));
      harness.app.get('/cookie', (req, res) {
        // Access cookies to trigger parsing — empty-value cookies should not appear
        final token = req.cookies.where((c) => c.name == 'token').firstOrNull;
        res.json({'hasEmpty': token != null});
      });
      // Send a cookie with no value
      final r = await harness.get('/cookie',
          headers: {'Cookie': 'token='});
      expect(r.statusCode, 200);
      expect(r.body, contains('"hasEmpty":false'));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Response.isSse getter
  // ────────────────────────────────────────────────────────────────────────

  group('Response.isSse', () {
    test('isSse is false by default', () {
      final res = Response();
      expect(res.isSse, isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // IsolatedContainer — onDispose and resolveRoutePath fallback
  // ────────────────────────────────────────────────────────────────────────

  group('IsolatedContainer', () {
    test('onDispose clears cache and DI container', () async {
      final container = IsolatedContainer(prefix: '/svc');
      container.cache['key'] = 'value';
      container.registerSingleton<_AsyncValue>(_AsyncValue('test'));
      expect(container.isRegistered<_AsyncValue>(), isTrue);
      await container.onDispose();
      expect(container.cache, isEmpty);
      expect(container.isRegistered<_AsyncValue>(), isFalse);
    });

    test('resolveRoutePath falls through when path does not start with prefix', () async {
      // Mount a sub-container and send a request that doesn't match the prefix
      // — the IsolatedContainer's resolveRoutePath returns the raw path
      final harness = TestServerHarness();
      final sub = IsolatedContainer(prefix: '/api');
      sub.get('/ping', (req, res) => res.text('pong'));
      sub.mount(harness.app);

      // This hits the parent router, not the sub-container fallback
      final r = await harness.get('/other/path');
      expect(r.statusCode, 404);
      await harness.dispose();
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // SSE sink — closed error, retry, stopKeepAlive
  // ────────────────────────────────────────────────────────────────────────

  group('SSE sink edge cases', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('sendEvent with retry param writes retry line', () async {
      harness.app.get('/sse-retry', (req, res) async {
        await res.sse((sink) async {
          await sink.sendEvent('data', retry: 3000);
          await sink.close();
        });
      });
      await harness.start();
      final ioClient = HttpClient();
      try {
        final req = await ioClient.getUrl(harness.uri('/sse-retry'));
        req.headers.add('Accept', 'text/event-stream');
        final resp = await req.close();
        final body = await resp.transform(const SystemEncoding().decoder).join();
        expect(body, contains('retry: 3000'));
        expect(body, contains('data: data'));
      } finally {
        ioClient.close();
      }
    });

    test('stopKeepAlive cancels keep-alive timer', () async {
      harness.app.get('/sse-ka', (req, res) async {
        await res.sse((sink) async {
          sink.startKeepAlive(const Duration(hours: 1)); // won't fire
          sink.stopKeepAlive(); // cancel it
          await sink.sendEvent('ok');
          await sink.close();
        });
      });
      await harness.start();
      final ioClient = HttpClient();
      try {
        final req = await ioClient.getUrl(harness.uri('/sse-ka'));
        req.headers.add('Accept', 'text/event-stream');
        final resp = await req.close();
        final body = await resp.transform(const SystemEncoding().decoder).join();
        expect(body, contains('data: ok'));
      } finally {
        ioClient.close();
      }
    });
  });
}

// ────────────────────────────────────────────────────────────────────────────
// Helper types
// ────────────────────────────────────────────────────────────────────────────

/// Minimal concrete SessionStore that uses default no-op implementations
/// for touch, cleanup, and dispose.
class _MinimalSessionStore extends SessionStore {
  @override
  Future<Map<String, dynamic>?> load(String id) async => null;

  @override
  Future<void> save(String id, Map<String, dynamic> data,
      {Duration? ttl}) async {}

  @override
  Future<void> destroy(String id) async {}
}

class _AsyncValue {
  _AsyncValue(this.value);
  final String value;
}

class _AsyncLazy {}
