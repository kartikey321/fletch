import 'dart:convert';
import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('HEAD and OPTIONS routes', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('HEAD route is handled', () async {
      harness.app.head('/ping', (req, res) => res.text(''));
      final r = await harness.send('HEAD', '/ping');
      expect(r.statusCode, 200);
    });

    test('OPTIONS route is handled', () async {
      harness.app.options('/opts', (req, res) {
        res.setHeader('Allow', 'GET, POST, OPTIONS');
        res.setStatus(HttpStatus.noContent);
      });
      final r = await harness.send('OPTIONS', '/opts');
      expect(r.statusCode, 204);
      expect(r.headers['allow'], contains('GET'));
    });
  });

  group('DI container methods on BaseContainer', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('registerSingleton() makes instance available in handlers', () async {
      harness.app.registerSingleton<_Config>(_Config('prod'));
      harness.app.get('/config', (req, res) {
        final cfg = req.container.get<_Config>();
        res.text(cfg.env);
      });
      final r = await harness.get('/config');
      expect(r.body, 'prod');
    });

    test('registerFactory() creates new instance per access', () async {
      var count = 0;
      harness.app.registerFactory<_Counter>(() => _Counter(++count));
      harness.app.get('/counter', (req, res) {
        final c = req.container.get<_Counter>();
        res.text('${c.value}');
      });
      final r1 = await harness.get('/counter');
      final r2 = await harness.get('/counter');
      // Factory is called each time get() is called; values differ
      expect(int.parse(r1.body), greaterThanOrEqualTo(1));
      expect(int.parse(r2.body), greaterThan(int.parse(r1.body)));
    });

    test('registerLazySingleton() creates instance only on first access', () async {
      var created = 0;
      harness.app.registerLazySingleton<_Lazy>(() {
        created++;
        return _Lazy();
      });
      harness.app.get('/lazy', (req, res) {
        req.container.get<_Lazy>();
        res.text('$created');
      });
      await harness.get('/lazy');
      final r2 = await harness.get('/lazy');
      expect(r2.body, '1'); // only created once
    });

    test('isRegistered() returns true after registration', () {
      harness.app.registerSingleton<_Config>(_Config('test'));
      expect(harness.app.isRegistered<_Config>(), isTrue);
      expect(harness.app.isRegistered<_Counter>(), isFalse);
    });

    test('unregister() removes the binding', () {
      harness.app.registerSingleton<_Config>(_Config('tmp'));
      expect(harness.app.isRegistered<_Config>(), isTrue);
      harness.app.unregister<_Config>();
      expect(harness.app.isRegistered<_Config>(), isFalse);
    });
  });

  group('hotReload() / reassemble()', () {
    test('reassemble() with no factory is a no-op', () {
      final app = Fletch();
      expect(() => app.reassemble(), returnsNormally);
    });

    test('hotReload() registers factory; reassemble() re-registers routes', () async {
      final app = Fletch();
      var handlerBody = 'v1';

      void registerRoutes(Fletch a) {
        a.get('/version', (req, res) => res.text(handlerBody));
      }

      // hotReload on BaseContainer (not the Fletch override which needs VM service)
      (app as dynamic).hotReload(() => registerRoutes(app));
      registerRoutes(app);

      final server = await app.listen(0, address: InternetAddress.loopbackIPv4);
      try {
        final port = server.port;
        final r1 = await http.get(Uri.parse('http://localhost:$port/version'));
        expect(r1.body, 'v1');

        handlerBody = 'v2';
        app.reassemble();

        final r2 = await http.get(Uri.parse('http://localhost:$port/version'));
        expect(r2.body, 'v2');
      } finally {
        await app.close();
        await server.close(force: true);
      }
    });
  });

  group('serveWith()', () {
    test('attaches app to pre-configured server', () async {
      final app = Fletch();
      app.get('/sw', (req, res) => res.text('serve-with'));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await app.serveWith(server);
      try {
        final r = await http.get(
          Uri.parse('http://localhost:${server.port}/sw'),
        );
        expect(r.statusCode, 200);
        expect(r.body, 'serve-with');
      } finally {
        await app.close();
        await server.close(force: true);
      }
    });
  });

  group('enableHealthCheck()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('health endpoint returns status ok with uptime', () async {
      harness.app.enableHealthCheck();
      final r = await harness.get('/health');
      expect(r.statusCode, 200);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['status'], 'ok');
      expect(body.containsKey('uptime'), isTrue);
      expect(body.containsKey('activeRequests'), isTrue);
    });
  });

  group('Controller additional HTTP methods', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('controller registers PUT, PATCH, DELETE routes', () async {
      harness.app.useController('/items', _ItemController());

      final put = await harness.send('PUT', '/items/1');
      expect(put.statusCode, 200);
      expect(put.body, 'put:1');

      final patch = await harness.send('PATCH', '/items/1');
      expect(patch.statusCode, 200);
      expect(patch.body, 'patch:1');

      final delete = await harness.send('DELETE', '/items/1');
      expect(delete.statusCode, 200);
      expect(delete.body, 'delete:1');
    });
  });

  group('Fletch validateConfig warnings', () {
    test('secureCookies: false logs a warning but does not throw', () {
      expect(
        () => Fletch(secureCookies: false),
        returnsNormally,
      );
    });

    test('no sessionSecret logs a warning but does not throw', () {
      expect(() => Fletch(), returnsNormally);
    });

    test('sessionSecret shorter than 32 chars throws ArgumentError', () {
      expect(
        () => Fletch(sessionSecret: 'short'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('requestTimeout of zero throws ArgumentError', () {
      expect(
        () => Fletch(requestTimeout: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('null requestTimeout is allowed', () {
      expect(() => Fletch(requestTimeout: null), returnsNormally);
    });
  });

  group('IsolatedContainer.listen() standalone', () {
    test('isolated container serves requests on its own port', () async {
      final container = IsolatedContainer();
      container.get('/hello', (req, res) => res.text('standalone'));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(); // free the port; listen() will bind fresh

      // Use listen() which binds its own server
      final bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final boundPort = bound.port;
      await bound.close();

      // listen() on IsolatedContainer
      final listenFuture = container.listen(boundPort,
          address: InternetAddress.loopbackIPv4);

      await Future.delayed(const Duration(milliseconds: 50));

      try {
        final r = await http.get(
          Uri.parse('http://localhost:$boundPort/hello'),
        );
        expect(r.statusCode, 200);
        expect(r.body, 'standalone');
      } finally {
        listenFuture.ignore();
      }
    });
  });

  group('IsolatedContainer prefix edge cases', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('prefix without leading slash is normalized', () async {
      final sub = IsolatedContainer(prefix: 'api');
      sub.get('/ping', (req, res) => res.text('pong'));
      sub.mount(harness.app);

      final r = await harness.get('/api/ping');
      expect(r.statusCode, 200);
    });

    test('prefix with trailing slash is trimmed', () async {
      final sub = IsolatedContainer(prefix: '/v1/');
      sub.get('/info', (req, res) => res.text('info'));
      sub.mount(harness.app);

      final r = await harness.get('/v1/info');
      expect(r.statusCode, 200);
    });
  });

  group('RadixRouter edge cases', () {
    test('addIsolatedRouter throws on duplicate prefix', () {
      final router = RadixRouter();
      router.addIsolatedRouter('/api', RadixRouter());
      expect(
        () => router.addIsolatedRouter('/api', RadixRouter()),
        throwsA(isA<RouteConflictError>()),
      );
    });

    test('clear() removes routes and isolated routers', () {
      final router = RadixRouter();
      router.addRoute('GET', '/exists', (req, res) {});
      router.addIsolatedRouter('/sub', RadixRouter());
      router.clear();

      expect(router.findRoute('GET', '/exists'), isNull);
    });

    test('invalid path segment throws FormatException', () {
      final router = RadixRouter();
      expect(
        () => router.addRoute('GET', '/bad/:(invalid)', (req, res) {}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

// --- Helper types ---

class _Config {
  _Config(this.env);
  final String env;
}

class _Counter {
  _Counter(this.value);
  final int value;
}

class _Lazy {}

class _ItemController extends Controller {
  @override
  void registerRoutes(ControllerOptions options) {
    options.put('/:id', (req, res) => res.text('put:${req.params['id']}'));
    options.patch('/:id', (req, res) => res.text('patch:${req.params['id']}'));
    options.delete('/:id', (req, res) => res.text('delete:${req.params['id']}'));
  }
}
