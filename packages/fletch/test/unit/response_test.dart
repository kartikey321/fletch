import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Response.html()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('sets Content-Type text/html and body', () async {
      harness.app.get('/html', (req, res) => res.html('<h1>Hello</h1>'));
      final r = await harness.get('/html');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('text/html'));
      expect(r.body, '<h1>Hello</h1>');
    });

    test('html() accepts optional statusCode', () async {
      harness.app.get('/html-status', (req, res) {
        res.html('<p>created</p>', statusCode: 201);
      });
      final r = await harness.get('/html-status');
      expect(r.statusCode, 201);
    });
  });

  group('Response.xml()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('sets Content-Type application/xml and body', () async {
      harness.app.get('/xml', (req, res) => res.xml('<root/>'));
      final r = await harness.get('/xml');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('application/xml'));
      expect(r.body, '<root/>');
    });

    test('xml() accepts optional statusCode', () async {
      harness.app.get('/xml-status', (req, res) {
        res.xml('<ok/>', statusCode: 202);
      });
      final r = await harness.get('/xml-status');
      expect(r.statusCode, 202);
    });
  });

  group('Response.text()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('text() with statusCode sets status', () async {
      harness.app.get('/text-status', (req, res) {
        res.text('created', statusCode: 201);
      });
      final r = await harness.get('/text-status');
      expect(r.statusCode, 201);
      expect(r.body, 'created');
    });
  });

  group('Response.status()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('status() sets status code and returns self for chaining', () async {
      harness.app.get('/status', (req, res) {
        res.status(202).text('accepted');
      });
      final r = await harness.get('/status');
      expect(r.statusCode, 202);
      expect(r.body, 'accepted');
    });
  });

  group('Response.redirect()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('redirect() sets 301 and Location header by default', () async {
      harness.app.get('/old', (req, res) => res.redirect('/new'));
      await harness.start();

      // Use dart:io client with followRedirects=false to inspect the raw 3xx
      final ioClient = HttpClient();
      try {
        final req = await ioClient.getUrl(harness.uri('/old'));
        req.followRedirects = false;
        final resp = await req.close();
        expect(resp.statusCode, 301);
        expect(resp.headers.value(HttpHeaders.locationHeader), '/new');
        await resp.drain();
      } finally {
        ioClient.close();
      }
    });

    test('redirect() accepts custom status code', () async {
      harness.app.get('/moved', (req, res) {
        res.redirect('/here', status: HttpStatus.temporaryRedirect);
      });
      await harness.start();

      final ioClient = HttpClient();
      try {
        final req = await ioClient.getUrl(harness.uri('/moved'));
        req.followRedirects = false;
        final resp = await req.close();
        expect(resp.statusCode, 307);
        expect(resp.headers.value(HttpHeaders.locationHeader), '/here');
        await resp.drain();
      } finally {
        ioClient.close();
      }
    });
  });

  group('Response.file()', () {
    late TestServerHarness harness;
    late File tempFile;

    setUp(() {
      harness = TestServerHarness();
      tempFile = File('${Directory.systemTemp.path}/fletch_test_${DateTime.now().microsecondsSinceEpoch}.txt');
      tempFile.writeAsStringSync('file content');
    });
    tearDown(() async {
      await harness.dispose();
      if (tempFile.existsSync()) tempFile.deleteSync();
    });

    test('file() sends file contents when it exists', () async {
      harness.app.get('/file', (req, res) async {
        await res.file(tempFile);
      });
      final r = await harness.get('/file');
      expect(r.statusCode, 200);
      expect(r.body, 'file content');
    });

    test('file() returns 404 when file does not exist', () async {
      harness.app.get('/missing-file', (req, res) async {
        await res.file(File('/nonexistent/path/file.txt'));
      });
      final r = await harness.get('/missing-file');
      expect(r.statusCode, 404);
      expect(r.body, contains('File not found'));
    });
  });

  group('Response.clearCookie()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('clearCookie() sets expired cookie to delete from client', () async {
      harness.app.get('/clear', (req, res) {
        res.clearCookie('auth');
      });
      final r = await harness.get('/clear');
      final setCookie = r.headers['set-cookie'] ?? '';
      expect(setCookie, contains('auth='));
      expect(setCookie, contains('Max-Age=0'));
    });
  });

  group('Response.hasCookie()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('hasCookie() returns true for queued cookie without path filter', () async {
      harness.app.get('/has', (req, res) {
        res.cookie('token', 'abc');
        res.json({'has': res.hasCookie('token')});
      });
      final r = await harness.get('/has');
      expect(r.body, contains('"has":true'));
    });

    test('hasCookie() with path filter matches correctly', () async {
      harness.app.get('/has-path', (req, res) {
        res.cookie('token', 'abc', path: '/api');
        final hasApi = res.hasCookie('token', path: '/api');
        final hasRoot = res.hasCookie('token', path: '/');
        res.json({'hasApi': hasApi, 'hasRoot': hasRoot});
      });
      final r = await harness.get('/has-path');
      expect(r.body, contains('"hasApi":true'));
      expect(r.body, contains('"hasRoot":false'));
    });
  });

  group('Response cookie replacement', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('setting same cookie name+path replaces previous value', () async {
      harness.app.get('/replace', (req, res) {
        res.cookie('token', 'first', path: '/');
        res.cookie('token', 'second', path: '/'); // replaces
        res.text('ok');
      });
      final r = await harness.get('/replace');
      final setCookie = r.headers['set-cookie'] ?? '';
      // Only one cookie should appear; value should be 'second'
      expect(setCookie, contains('token=second'));
      expect(setCookie, isNot(contains('token=first')));
    });
  });

  group('Response constructor with initial headers', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('headers passed to constructor are present on the response', () async {
      harness.app.get('/init-headers', (req, res) {
        // Create a response with pre-populated headers directly
        final r2 = Response(headers: {'X-Pre': 'set'});
        expect(r2.headers['X-Pre'], 'set');
        res.text('ok');
      });
      final r = await harness.get('/init-headers');
      expect(r.statusCode, 200);
    });
  });

  group('Response.stream()', () {
    late TestServerHarness harness;
    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('streams bytes to client', () async {
      harness.app.get('/stream', (req, res) async {
        final data = Stream.fromIterable([
          [72, 101, 108, 108, 111], // "Hello"
        ]);
        await res.stream(data, contentType: 'text/plain', statusCode: 200);
      });
      final r = await harness.get('/stream');
      expect(r.statusCode, 200);
      expect(r.body, 'Hello');
    });

    test('stream() throws if body already set', () async {
      harness.app.get('/stream-conflict', (req, res) async {
        res.text('already set');
        try {
          await res.stream(const Stream.empty());
          res.json({'threw': false});
        } catch (e) {
          res.json({'threw': true});
        }
      });
      final r = await harness.get('/stream-conflict');
      expect(r.body, contains('"threw":true'));
    });
  });
}
