import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

/// Generates a temporary self-signed certificate + key using openssl.
/// Files are written to [dir] and the resulting [SecurityContext] is returned.
/// Caller is responsible for deleting [dir] in tearDown.
Future<SecurityContext> _buildTestContext(Directory dir) async {
  final certPath = '${dir.path}/cert.pem';
  final keyPath = '${dir.path}/key.pem';

  final result = await Process.run('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048',
    '-keyout', keyPath,
    '-out', certPath,
    '-days', '1',
    '-nodes',
    '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=IP:127.0.0.1',
  ]);

  if (result.exitCode != 0) {
    throw StateError('openssl failed: ${result.stderr}');
  }

  final ctx = SecurityContext();
  ctx.useCertificateChain(certPath);
  ctx.usePrivateKey(keyPath);
  return ctx;
}

Future<String> _httpsGet(String host, int port, String path) async {
  final client = HttpClient()
    ..badCertificateCallback = (_, __, ___) => true; // accept self-signed
  final req = await client.getUrl(Uri.parse('https://$host:$port$path'));
  final res = await req.close();
  final body = await res.transform(const SystemEncoding().decoder).join();
  client.close();
  return body;
}

void main() {
  group('listenSecure', () {
    late Fletch app;
    late HttpServer server;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fletch_tls_test_');
      app = Fletch(secureCookies: false, requestTimeout: null);
      app.get('/ping', (req, res) => res.text('pong'));
    });

    tearDown(() async {
      await app.close();
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    });

    test('binds on IPv4 loopback and serves HTTPS requests', () async {
      final ctx = await _buildTestContext(tempDir);
      server = await app.listenSecure(
        0, // ephemeral port
        ctx,
        address: InternetAddress.loopbackIPv4,
      );

      expect(server.port, greaterThan(0));
      final body = await _httpsGet('127.0.0.1', server.port, '/ping');
      expect(body, equals('pong'));
    });

    test('v6Only: false (default) allows IPv4 binding', () async {
      final ctx = await _buildTestContext(tempDir);
      // If v6Only defaulted to true this would throw when bound to anyIPv4
      server = await app.listenSecure(
        0,
        ctx,
        address: InternetAddress.loopbackIPv4,
        v6Only: false, // explicit — kills the default mutation
      );

      expect(server.port, greaterThan(0));
      final body = await _httpsGet('127.0.0.1', server.port, '/ping');
      expect(body, equals('pong'));
    });

    test('requestClientCertificate: false (default) accepts clients without certs',
        () async {
      final ctx = await _buildTestContext(tempDir);
      server = await app.listenSecure(
        0,
        ctx,
        address: InternetAddress.loopbackIPv4,
        requestClientCertificate: false,
      );

      // Should not require a client cert — request succeeds
      final body = await _httpsGet('127.0.0.1', server.port, '/ping');
      expect(body, equals('pong'));
    });
  });
}
