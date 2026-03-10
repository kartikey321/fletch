import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fletch/fletch.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Request parsing', () {
    TestServerHarness? harness;

    setUp(() => harness = TestServerHarness());

    tearDown(() => harness?.dispose());

    test('parses JSON bodies and caches the result', () async {
      harness!.app.post('/json', (req, res) async {
        final first = await req.body;
        final second = await req.body;
        res.json({'first': first, 'sameInstance': identical(first, second)});
      });

      final response = await harness!.post(
        '/json',
        body: '{"message":"hi"}',
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
      );

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      expect(response.statusCode, 200);
      expect(payload['first'], equals({'message': 'hi'}));
      expect(payload['sameInstance'], isTrue);
    });

    test('parses urlencoded forms', () async {
      harness!.app.post('/form', (req, res) async {
        final body = await req.body as Map<String, String>;
        res.json(body);
      });

      final response = await harness!.post(
        '/form',
        body: 'foo=bar&baz=qux',
        headers: {
          HttpHeaders.contentTypeHeader:
              'application/x-www-form-urlencoded; charset=utf-8'
        },
      );

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      expect(response.statusCode, 200);
      expect(payload, containsPair('foo', 'bar'));
      expect(payload, containsPair('baz', 'qux'));
    });

    test('returns raw bytes for unknown content type', () async {
      harness!.app.post('/bytes', (req, res) async {
        final body = await req.body as Uint8List;
        res.bytes(body, statusCode: 201);
      });

      final bytes = utf8.encode('raw-data');
      final response = await harness!.post(
        '/bytes',
        body: bytes,
        headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
      );

      expect(response.statusCode, 201);
      expect(response.bodyBytes, bytes);
    });

    test('rejects payload exceeding maxBodySize with 413', () async {
      await harness?.dispose();
      harness = TestServerHarness(
        app: Fletch(maxBodySize: 256),
      );
      harness!.app.post('/limit', (req, res) async {
        await req.body; // Triggers body read and size enforcement
        res.text('ok');
      });

      final body = List.filled(1024, 65); // 1KB
      final response = await harness!.post(
        '/limit',
        body: body,
        headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
      );

      expect(response.statusCode, 413);
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      expect(payload['error'], contains('Payload Too Large'));
    });
  });

  group('Multipart parsing', () {
    TestServerHarness? harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() => harness?.dispose());

    test('merges fields and files into formData', () async {
      await harness!.start();
      harness!.app.post('/upload', (req, res) async {
        final formData = await req.formData;
        res.json({
          'fields': formData.map(
            (key, value) => MapEntry(key, value is String ? value : null),
          ),
          'fileLengths': formData.map((key, value) => MapEntry(
              key,
              value is List
                  ? (value.first as http.MultipartFile).length
                  : null)),
        });
      });

      final request = http.MultipartRequest(
        'POST',
        harness!.uri('/upload'),
      )
        ..fields['name'] = 'demo'
        ..files.add(http.MultipartFile.fromBytes(
          'avatar',
          List.filled(10, 1),
          filename: 'avatar.png',
        ));

      final streamed = await harness!.sendMultipart(request);
      final response = await http.Response.fromStream(streamed);
      final payload = jsonDecode(response.body) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(payload['fields']['name'], 'demo');
      expect(payload['fileLengths']['avatar'], 10);
    });

    test('enforces maxFileSize during multipart parsing', () async {
      await harness?.dispose();
      harness = TestServerHarness(
        app: Fletch(maxFileSize: 64 * 2, maxBodySize: 1024),
      );

      await harness!.start();
      harness!.app.post('/files', (req, res) async {
        await req.files;
        res.text('ok');
      });

      final request = http.MultipartRequest(
        'POST',
        harness!.uri('/files'),
      )..files.add(http.MultipartFile.fromBytes(
          'file',
          List.filled(200, 1), // Exceeds maxFileSize
          filename: 'big.bin',
        ));

      final response =
          await http.Response.fromStream(await harness!.sendMultipart(request));

      expect(response.statusCode, 413);
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      expect(payload['error'], contains('File too large'));
    });
  });

  group('Session cookies', () {
    TestServerHarness? harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() => harness?.dispose());

    test('sets HttpOnly session cookie when missing', () async {
      // Session cookie is only emitted when the handler actually accesses
      // req.session (lazy session initialisation).
      harness!.app.get('/session', (req, res) {
        req.session['touched'] = true; // access the session
        res.text('OK');
      });

      final response = await harness!.get('/session');

      final cookie = response.headers[HttpHeaders.setCookieHeader];
      expect(response.statusCode, 200);
      expect(cookie, contains(Request.sessionCookieName));
      expect(cookie, contains('HttpOnly'));
    });

    test('reuses provided session cookie', () async {
      final cookieHeader =
          '${Request.sessionCookieName}=existing-session; Path=/';
      harness!.app.get('/session', (req, res) => res.text('OK'));

      final response = await harness!.get(
        '/session',
        headers: {HttpHeaders.cookieHeader: cookieHeader},
      );

      expect(response.statusCode, 200);
      expect(response.headers[HttpHeaders.setCookieHeader], isNull);
    });

    test('propagates request id to response header', () async {
      harness!.app.get('/trace', (req, res) => res.text('traced'));

      final response = await harness!.get(
        '/trace',
        headers: {'x-request-id': 'abc-123'},
      );

      expect(response.headers['x-request-id'], equals('abc-123'));
    });
  });
}
