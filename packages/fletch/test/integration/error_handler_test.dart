import 'dart:convert';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Custom error handler', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('custom error handler receives error and sends response', () async {
      harness.app.setErrorHandler((error, req, res) async {
        res.setStatus(422);
        res.json({'custom': true, 'msg': error.toString()});
        await res.send(req.httpRequest.response);
      });
      harness.app.get('/fail', (req, res) => throw Exception('boom'));

      final r = await harness.get('/fail');
      expect(r.statusCode, 422);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['custom'], isTrue);
      expect(body['msg'], contains('boom'));
    });

    test('HttpError is handled with correct status code', () async {
      harness.app.get('/http-err', (req, res) {
        throw HttpError(409, 'Conflict', {'field': 'email'});
      });

      final r = await harness.get('/http-err');
      expect(r.statusCode, 409);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['error'], 'Conflict');
    });

    test('custom error handler that does not send response falls back to default', () async {
      harness.app.setErrorHandler((error, req, res) async {
        // intentionally does NOT send a response
      });
      harness.app.get('/no-send', (req, res) => throw Exception('unhandled'));

      final r = await harness.get('/no-send');
      // Default error handler kicks in — 500
      expect(r.statusCode, 500);
    });

    test('custom error handler that throws falls back to default', () async {
      harness.app.setErrorHandler((error, req, res) {
        throw Exception('error in handler');
      });
      harness.app.get('/double-fault', (req, res) => throw Exception('first'));

      final r = await harness.get('/double-fault');
      expect(r.statusCode, 500);
    });
  });

  group('HttpError subclasses', () {
    test('ValidationError carries 400 status', () {
      final e = ValidationError('bad input', {'field': 'name'});
      expect(e.statusCode, 400);
      expect(e.message, 'bad input');
      expect(e.data, {'field': 'name'});
    });

    test('NotFoundError carries 404 status', () {
      final e = NotFoundError('not here');
      expect(e.statusCode, 404);
    });

    test('UnauthorizedError carries 401 status', () {
      final e = UnauthorizedError('no auth');
      expect(e.statusCode, 401);
    });

    test('RouteConflictError carries 409 status', () {
      final e = RouteConflictError('duplicate route');
      expect(e.statusCode, 409);
    });

    test('HttpError.toString() contains status and message', () {
      final e = HttpError(503, 'Service Unavailable');
      expect(e.toString(), contains('503'));
      expect(e.toString(), contains('Service Unavailable'));
    });
  });

  group('Session error resilience', () {
    late TestServerHarness harness;

    setUp(() {
      harness = TestServerHarness(
        app: Fletch(sessionStore: _ThrowingSessionStore()),
      );
    });
    tearDown(() => harness.dispose());

    test('session load failure does not crash the request', () async {
      harness.app.get('/load-fail', (req, res) {
        req.session['x'] = 1; // touch session
        res.text('ok');
      });

      // Force a returning-visitor scenario by sending a fake cookie
      final r = await harness.get('/load-fail', headers: {
        'Cookie': '${Request.sessionCookieName}=fake-id',
      });
      expect(r.statusCode, 200);
    });

    test('session save failure does not crash the request', () async {
      harness.app.get('/save-fail', (req, res) {
        req.session['x'] = 1;
        res.text('ok');
      });
      final r = await harness.get('/save-fail');
      expect(r.statusCode, 200);
    });
  });
}

/// A session store that always throws to verify error resilience.
class _ThrowingSessionStore implements SessionStore {
  @override
  Future<Map<String, dynamic>?> load(String id) async {
    throw Exception('store unavailable');
  }

  @override
  Future<void> save(String id, Map<String, dynamic> data, {Duration? ttl}) async {
    throw Exception('store unavailable');
  }

  @override
  Future<void> destroy(String id) async {}

  @override
  Future<void> touch(String id, {Duration? ttl}) async {}

  @override
  Future<void> cleanup() async {}

  @override
  Future<void> dispose() async {}
}
