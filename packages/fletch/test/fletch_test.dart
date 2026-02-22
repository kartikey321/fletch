import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('Application', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());

    tearDown(() async => harness.dispose());

    test('GET / returns 200 with correct body', () async {
      harness.app
          .get('/', (Request req, Response res) => res.text('Hello World!'));

      final response = await harness.get('/');

      expect(response.statusCode, 200);
      expect(response.body, 'Hello World!');
      expect(
          response.headers['set-cookie'], contains(Request.sessionCookieName));
    });

    test('POST / returns 201 with JSON response', () async {
      harness.app.post(
        '/',
        (Request req, Response res) =>
            res.json({'success': true}, statusCode: 201),
      );

      final response = await harness.post('/');

      expect(response.statusCode, 201);
      expect(response.headers['content-type'], contains('application/json'));
      expect(response.body, '{"success":true}');
    });

    test('Unknown route returns 404 with JSON payload', () async {
      final response = await harness.get('/not_found');

      expect(response.statusCode, 404);
      expect(response.headers['content-type'], contains('application/json'));
    });
    test('Reuses existing session cookie when provided', () async {
      final cookieHeader = '${Request.sessionCookieName}=existing-session';

      harness.app.get('/', (req, res) => res.text('OK'));

      final response = await harness.get(
        '/',
        headers: {HttpHeaders.cookieHeader: cookieHeader},
      );

      expect(response.statusCode, 200);
      // No duplicate cookie should be issued when already provided
      expect(response.headers['set-cookie'], isNull);
    });
  });

  group('Middleware', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() async => harness.dispose());

    test('Runs middleware in order', () async {
      final order = <int>[];

      harness.app.use((req, res, next) {
        order.add(1);
        return next();
      });

      harness.app.use((req, res, next) {
        order.add(2);
        return next();
      });

      harness.app.get('/middleware', (req, res) {
        order.add(3);
        res.text('OK');
      });

      final response = await harness.get('/middleware');

      expect(response.statusCode, 200);
      expect(order, [1, 2, 3]);
    });

    test('Middleware can modify response', () async {
      harness.app.use((req, res, next) {
        res.headers['X-Custom-Header'] = '123';
        return next();
      });

      harness.app.get('/header', (req, res) => res.text('OK'));

      final response = await harness.get('/header');

      expect(response.statusCode, 200);
      expect(response.headers['x-custom-header'], '123');
    });
  });

  group('Error Handling', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() async => harness.dispose());

    test('Unhandled error returns 500', () async {
      harness.app.get('/error', (req, res) => throw Exception('Test Error'));

      final response = await harness.get('/error');

      expect(response.statusCode, 500);
      expect(response.headers['content-type'], contains('application/json'));
    });
  });

  group('Route Parameters', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() async => harness.dispose());

    test('Parses route parameters', () async {
      harness.app.get('/users/:id', (req, res) {
        res.text('User ID: ${req.params['id']}');
      });

      final response = await harness.get('/users/123');

      expect(response.statusCode, 200);
      expect(response.body, 'User ID: 123');
    });
  });

  group('Isolated Container', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() async => harness.dispose());

    test('Routes and middleware execute in isolated scope', () async {
      final isolated = IsolatedContainer(prefix: '/island');
      isolated.use((req, res, next) {
        res.setHeader('X-Isolated', 'true');
        return next();
      });
      isolated.get('/', (req, res) => res.text('Isolated Root'));

      isolated.mount(harness.app);

      final response = await harness.get('/island');

      expect(response.statusCode, 200);
      expect(response.body, 'Isolated Root');
      expect(response.headers['x-isolated'], 'true');
    });

    test('Uses independent dependency injection scope', () async {
      final isolated = IsolatedContainer(prefix: '/island');

      harness.app.inject<Dependency>(Dependency('parent'));
      isolated.inject<Dependency>(Dependency('isolated'));

      isolated.get('/value', (req, res) {
        final dep = req.container.get<Dependency>();
        res.json({'value': dep.id});
      });

      isolated.mount(harness.app);

      final response = await harness.get('/island/value');

      expect(response.statusCode, 200);
      expect(response.body, '{"value":"isolated"}');

      final parentResponse = await harness.get('/missing');
      expect(parentResponse.statusCode, 404);
    });
  });
}

class TestServerHarness {
  final Fletch app = Fletch();
  HttpServer? _server;

  Future<http.Response> get(String path, {Map<String, String>? headers}) async {
    await _ensureServer();
    return http.get(_uri(path), headers: headers);
  }

  Future<http.Response> post(String path,
      {Object? body, Map<String, String>? headers}) async {
    await _ensureServer();
    return http.post(_uri(path), body: body, headers: headers);
  }

  Future<void> dispose() async {
    if (_server != null) {
      await _server!.close(force: true);
      await app.waitUntilClosed(_server!);
      _server = null;
    } else {
      await app.onDispose();
    }
  }

  Future<void> _ensureServer() async {
    if (_server != null) {
      return;
    }

    _server = await app.listen(0, address: InternetAddress.loopbackIPv4);
  }

  Uri _uri(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('http://localhost:${_server!.port}$normalized');
  }
}

class Dependency {
  Dependency(this.id);
  final String id;
}
