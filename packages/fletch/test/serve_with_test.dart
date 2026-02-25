import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal harness that binds via [app.serveWith] so we can test that path
/// without going through [app.listen].
class ServeWithHarness {
  ServeWithHarness({Fletch? app}) : app = app ?? Fletch(secureCookies: false);

  final Fletch app;
  HttpServer? _server;

  Future<void> start() async {
    if (_server != null) return;
    final raw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = await app.serveWith(raw);
  }

  Uri uri(String path) {
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('http://localhost:${_server!.port}$p');
  }

  Future<http.Response> get(String path, {Map<String, String>? headers}) async {
    await start();
    return http.get(uri(path), headers: headers);
  }

  Future<http.Response> post(String path,
      {Object? body, Map<String, String>? headers}) async {
    await start();
    return http.post(uri(path), body: body, headers: headers);
  }

  Future<void> dispose() async {
    final server = _server;
    if (server != null) {
      await app.close();
      await server.close(force: true);
      await app.waitUntilClosed(server);
      _server = null;
    } else {
      await app.onDispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  group('serveWith()', () {
    late ServeWithHarness harness;

    setUp(() => harness = ServeWithHarness());
    tearDown(() => harness.dispose());

    test('returns the same HttpServer that was passed in', () async {
      final raw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final returned = await harness.app.serveWith(raw);
      expect(returned, same(raw));
      await raw.close(force: true);
    });

    test('handles a GET route correctly', () async {
      harness.app.get('/hello', (req, res) => res.text('world'));

      final response = await harness.get('/hello');

      expect(response.statusCode, 200);
      expect(response.body, 'world');
    });

    test('handles POST, PUT, and DELETE routes', () async {
      harness.app
        ..post('/items', (req, res) => res.json({'action': 'created'}, statusCode: 201))
        ..put('/items/1', (req, res) => res.json({'action': 'updated'}))
        ..delete('/items/1', (req, res) => res.json({'action': 'deleted'}));

      final post = await harness.post('/items');
      expect(post.statusCode, 201);
      expect(post.body, contains('created'));

      final put = await http.put(harness.uri('/items/1'));
      expect(put.statusCode, 200);
      expect(put.body, contains('updated'));

      final delete = await http.delete(harness.uri('/items/1'));
      expect(delete.statusCode, 200);
      expect(delete.body, contains('deleted'));
    });

    test('runs global middleware before the route handler', () async {
      final calls = <String>[];

      harness.app
        ..use((req, res, next) {
          calls.add('middleware');
          return next();
        })
        ..get('/mw', (req, res) {
          calls.add('handler');
          res.text('ok');
        });

      final response = await harness.get('/mw');

      expect(response.statusCode, 200);
      expect(calls, ['middleware', 'handler']);
    });

    test('runs per-route middleware', () async {
      harness.app.get(
        '/guarded',
        (req, res) => res.text('pass'),
        middleware: [
          (req, res, next) {
            res.setHeader('X-Guarded', 'yes');
            return next();
          },
        ],
      );

      final response = await harness.get('/guarded');

      expect(response.statusCode, 200);
      expect(response.headers['x-guarded'], 'yes');
    });

    test('returns 404 JSON for an unregistered route', () async {
      final response = await harness.get('/no-such-route');

      expect(response.statusCode, 404);
      expect(response.headers['content-type'], contains('application/json'));
    });

    test('returns 500 JSON when a handler throws', () async {
      harness.app.get('/boom', (req, res) => throw Exception('oops'));

      final response = await harness.get('/boom');

      expect(response.statusCode, 500);
      expect(response.headers['content-type'], contains('application/json'));
    });

    test('route params are accessible from the request', () async {
      harness.app.get('/users/:id', (req, res) {
        res.json({'id': req.params['id']});
      });

      final response = await harness.get('/users/42');

      expect(response.statusCode, 200);
      expect(response.body, contains('42'));
    });

    test('waitUntilClosed resolves after the server is closed', () async {
      await harness.start();
      final server = harness._server!;

      // Close the raw server from the outside (simulates an OS-level close)
      final waitFuture = harness.app.waitUntilClosed(server);
      await server.close(force: true);

      // Should resolve without hanging
      await waitFuture.timeout(const Duration(seconds: 5));
    });

    test('two independent apps each served via serveWith respond correctly',
        () async {
      final app1 = Fletch(secureCookies: false);
      final app2 = Fletch(secureCookies: false);

      app1.get('/ping', (req, res) => res.text('pong-1'));
      app2.get('/ping', (req, res) => res.text('pong-2'));

      final raw1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final raw2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      final server1 = await app1.serveWith(raw1);
      final server2 = await app2.serveWith(raw2);

      final r1 = await http.get(Uri.parse('http://localhost:${server1.port}/ping'));
      final r2 = await http.get(Uri.parse('http://localhost:${server2.port}/ping'));

      expect(r1.body, 'pong-1');
      expect(r2.body, 'pong-2');

      await app1.close();
      await raw1.close(force: true);
      await app1.waitUntilClosed(server1);

      await app2.close();
      await raw2.close(force: true);
      await app2.waitUntilClosed(server2);
    });
  });

  // -------------------------------------------------------------------------
  group('listen() bind options', () {
    test('backlog parameter is accepted without error', () async {
      final app = Fletch(secureCookies: false);
      final server =
          await app.listen(0, address: InternetAddress.loopbackIPv4, backlog: 128);

      expect(server.port, greaterThan(0));

      await app.close();
      await server.close(force: true);
      await app.waitUntilClosed(server);
    });

    test('shared=true allows two apps to bind on the same port', () async {
      final app1 = Fletch(secureCookies: false);
      final server1 = await app1.listen(
        0,
        address: InternetAddress.loopbackIPv4,
        shared: true,
      );
      final port = server1.port;

      final app2 = Fletch(secureCookies: false);
      // Should not throw — shared binding on the same port is valid
      final server2 = await app2.listen(
        port,
        address: InternetAddress.loopbackIPv4,
        shared: true,
      );

      expect(server2.port, equals(port));

      await app1.close();
      await server1.close(force: true);
      await app1.waitUntilClosed(server1);

      await app2.close();
      await server2.close(force: true);
      await app2.waitUntilClosed(server2);
    });

    test('default params still work (no regressions)', () async {
      final app = Fletch(secureCookies: false);
      app.get('/ok', (req, res) => res.text('ok'));

      final server = await app.listen(0, address: InternetAddress.loopbackIPv4);
      final response =
          await http.get(Uri.parse('http://localhost:${server.port}/ok'));

      expect(response.statusCode, 200);
      expect(response.body, 'ok');

      await app.close();
      await server.close(force: true);
      await app.waitUntilClosed(server);
    });
  });
}
