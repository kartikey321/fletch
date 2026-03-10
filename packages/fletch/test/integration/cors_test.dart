import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('CORS middleware', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('wildcard origin sets Access-Control-Allow-Origin: *', () async {
      harness.app.use(harness.app.cors());
      harness.app.get('/data', (req, res) => res.json({'ok': true}));

      final r = await harness.get('/data', headers: {'Origin': 'https://example.com'});
      expect(r.statusCode, 200);
      expect(r.headers['access-control-allow-origin'], '*');
      expect(r.headers['x-frame-options'], 'DENY');
      expect(r.headers['x-content-type-options'], 'nosniff');
    });

    test('specific allowed origin echoes origin and sets Vary header', () async {
      harness.app.use(harness.app.cors(
        allowedOrigins: ['https://trusted.com'],
      ));
      harness.app.get('/data', (req, res) => res.text('ok'));

      final r = await harness.get('/data', headers: {'Origin': 'https://trusted.com'});
      expect(r.statusCode, 200);
      expect(r.headers['access-control-allow-origin'], 'https://trusted.com');
      expect(r.headers['vary'], contains('Origin'));
    });

    test('disallowed origin returns 403', () async {
      harness.app.use(harness.app.cors(
        allowedOrigins: ['https://trusted.com'],
      ));
      harness.app.get('/data', (req, res) => res.text('ok'));

      final r = await harness.get('/data', headers: {'Origin': 'https://evil.com'});
      expect(r.statusCode, 403);
    });

    test('OPTIONS preflight returns 204 with CORS headers', () async {
      harness.app.use(harness.app.cors());
      harness.app.get('/api', (req, res) => res.text('ok'));
      // CORS middleware only runs for matched routes; register OPTIONS explicitly
      harness.app.options('/api', (req, res) {});

      final r = await harness.send('OPTIONS', '/api', headers: {
        'Origin': 'https://example.com',
        'Access-Control-Request-Method': 'GET',
      });
      expect(r.statusCode, HttpStatus.noContent);
      expect(r.headers['access-control-allow-origin'], isNotNull);
    });

    test('OPTIONS preflight with specific origins echoes Vary', () async {
      harness.app.use(harness.app.cors(
        allowedOrigins: ['https://app.com'],
      ));
      harness.app.get('/api', (req, res) => res.text('ok'));
      harness.app.options('/api', (req, res) {});

      final r = await harness.send('OPTIONS', '/api', headers: {
        'Origin': 'https://app.com',
        'Access-Control-Request-Headers': 'X-Custom-Header',
      });
      expect(r.statusCode, HttpStatus.noContent);
      expect(r.headers['access-control-allow-headers'], contains('X-Custom-Header'));
    });

    test('allowCredentials sets Allow-Credentials header', () async {
      harness.app.use(harness.app.cors(
        allowedOrigins: ['https://app.com'],
        allowCredentials: true,
      ));
      harness.app.get('/secure', (req, res) => res.text('ok'));

      final r = await harness.get('/secure', headers: {'Origin': 'https://app.com'});
      expect(r.statusCode, 200);
      expect(r.headers['access-control-allow-credentials'], 'true');
      expect(r.headers['access-control-allow-origin'], 'https://app.com');
    });

    test('allowCredentials with wildcard throws ArgumentError', () {
      expect(
        () => harness.app.cors(allowedOrigins: ['*'], allowCredentials: true),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('request with no Origin passes through without CORS headers', () async {
      harness.app.use(harness.app.cors());
      harness.app.get('/open', (req, res) => res.text('ok'));

      final r = await harness.get('/open');
      expect(r.statusCode, 200);
      // No CORS headers when no Origin header sent
      expect(r.headers['access-control-allow-origin'], isNull);
    });
  });
}
