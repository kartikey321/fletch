import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Security & robustness', () {
    TestServerHarness? harness;

    tearDown(() => harness?.dispose());

    test('times out hanging requests with 408', () async {
      final app = Fletch(requestTimeout: const Duration(milliseconds: 75));
      harness = TestServerHarness(app: app);

      harness!.app.get('/hang', (req, res) async {
        await Completer<void>().future;
      });

      final response = await harness!.get('/hang');

      expect(response.statusCode, HttpStatus.requestTimeout);
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      expect(payload['error'], contains('Request Timeout'));
    });

    test('recovers after rejecting oversized payloads', () async {
      final app = Fletch(maxBodySize: 512);
      harness = TestServerHarness(app: app);

      harness!.app
        ..post('/upload', (req, res) async {
          await req.body; // triggers size enforcement
          res.text('ok');
        })
        ..get('/health', (req, res) => res.text('ok'));

      final largeBody = List.filled(2048, 65);
      final rejection = await harness!.post(
        '/upload',
        body: largeBody,
        headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
      );
      final health = await harness!.get('/health');

      expect(rejection.statusCode, HttpStatus.requestEntityTooLarge);
      expect(jsonDecode(rejection.body), isA<Map>());
      expect(health.statusCode, HttpStatus.ok);
      expect(health.body, 'ok');
    });

    test('uses fallback error handler when custom handler fails', () async {
      harness = TestServerHarness();

      harness!.app.setErrorHandler((error, req, res) {
        throw StateError('broken handler');
      });

      harness!.app.get('/boom', (req, res) => throw Exception('boom'));

      final response = await harness!.get('/boom');

      expect(response.statusCode, HttpStatus.internalServerError);
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      expect(payload['error'], 'Internal Server Error');
    });

    test('session IDs are not predictable counters', () async {
      final app = Fletch(secureCookies: false);
      harness = TestServerHarness(app: app);

      harness!.app.get('/issue', (req, res) {
        req.session['touched'] = true;
        res.text(req.session.id);
      });

      final r1 = await harness!.get('/issue');
      final r2 = await harness!.get('/issue');

      expect(r1.statusCode, HttpStatus.ok);
      expect(r2.statusCode, HttpStatus.ok);
      expect(r1.body, isNot(equals(r2.body)));
      // Reject deterministic counter-based format like: ses_<prefix>_<n>
      expect(RegExp(r'^ses_[a-z0-9]+_\d+$').hasMatch(r1.body), isFalse);
      expect(RegExp(r'^ses_[a-z0-9]+_\d+$').hasMatch(r2.body), isFalse);
    });

    test('error detail is redacted by default (debug: false)', () async {
      harness = TestServerHarness();
      harness!.app.get('/fail', (req, res) {
        throw Exception('SocketException: DB at 10.0.0.1:5432 is down');
      });

      final r = await harness!.get('/fail');
      expect(r.statusCode, HttpStatus.internalServerError);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['error'], equals('Internal Server Error'));
      expect(body.containsKey('message'), isFalse);
    });

    test('error detail is exposed when debug: true', () async {
      final app = Fletch(debug: true, secureCookies: false);
      harness = TestServerHarness(app: app);
      harness!.app.get('/fail', (req, res) {
        throw Exception('secret DB address');
      });

      final r = await harness!.get('/fail');
      expect(r.statusCode, HttpStatus.internalServerError);
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['message'], contains('secret DB address'));
    });

    test('session.regenerate() changes ID and sets new cookie', () async {
      final app = Fletch(
        secureCookies: false,
        sessionSecret: 'test-secret-for-session-regen-32+chars',
      );
      harness = TestServerHarness(app: app);

      harness!.app.post('/login', (req, res) async {
        final oldId = req.session.id;
        await req.session.regenerate();
        req.session['userId'] = 'alice';
        res.json({'oldId': oldId, 'newId': req.session.id});
      });

      final r = await harness!.post('/login');
      expect(r.statusCode, HttpStatus.ok);

      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(body['oldId'], isNot(equals(body['newId'])));
      // A new Set-Cookie must be issued with the regenerated ID
      expect(r.headers[HttpHeaders.setCookieHeader], contains(Request.sessionCookieName));
    });

    test('sanitizedFilename strips path traversal sequences', () {
      final f = MultipartFile.fromBytes('f', [], filename: '../../etc/passwd');
      expect(f.sanitizedFilename, equals('passwd'));

      final w = MultipartFile.fromBytes('f', [], filename: r'..\..\windows\system32\config');
      expect(w.sanitizedFilename, equals('config'));

      final n = MultipartFile.fromBytes('f', [], filename: 'avatar.png');
      expect(n.sanitizedFilename, equals('avatar.png'));

      final noName = MultipartFile.fromBytes('f', []);
      expect(noName.sanitizedFilename, isNull);
    });

    test('MemorySessionStore evicts oldest when maxSessions reached', () async {
      final store = MemorySessionStore(maxSessions: 3);
      await store.save('a', {'x': 1});
      await store.save('b', {'x': 2});
      await store.save('c', {'x': 3});
      // All three present
      expect(await store.load('a'), isNotNull);

      // Adding a 4th evicts the oldest (a)
      await store.save('d', {'x': 4});
      expect(store.sessionCount, 3);
      expect(await store.load('a'), isNull); // evicted
      expect(await store.load('d'), isNotNull);
    });
  });
}
