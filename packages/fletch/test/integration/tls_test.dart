import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

// Self-signed certificate and key generated for localhost / 127.0.0.1.
// These are test-only credentials — never use in production.
const _testCert = '''
-----BEGIN CERTIFICATE-----
MIIDGjCCAgKgAwIBAgIUHUalpdfwZzaUY69y299Zn5AN5OUwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDMxMDIzMDkyMFoXDTM2MDMw
NzIzMDkyMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAn7rFnyt4L2Eiqg64x/fs6aL7jMytaRNkVGwAejtbGSLz
6/uPpXVrvBznvSyziGV8xxJeesgxofaNySPrMNUtkD6B36CFnDGITm+LhLyze6Vd
aIWA0IXGW2GlCQvgPu1VlVUF9MEJq5ekYMneydJa1NdwRBu07+uagnfXIORXpHuV
X8bc3+t20zi9s9FVW7irzA6mZObN98FjlZk7FcxjWRN16K8cYztw/6DKlgyyCbmA
mkr1kAL+1xyobJP8o7qZrj2HDge2QDOTypv+/NkiKRC9xlxkbvjdPph9gx4WVzsX
Kmfnsi5sjIGOmQ0mPX+uOhOnYQg4+Ho4FkNl/S2eMwIDAQABo2QwYjAdBgNVHQ4E
FgQU1YiSneQKX5QtTj++BV0+7cWlkzowHwYDVR0jBBgwFoAU1YiSneQKX5QtTj++
BV0+7cWlkzowDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMA0GCSqG
SIb3DQEBCwUAA4IBAQCPuvjvJXWnjnL4EXc7A0nceOP2VbMzlAPNmjNKqCvm4A1b
PaQkrhV4XdRrouMbK/xntZXlZm1ibd3JOw2XQI7s41S/aCFoh6rQXmMUw+8eS/Y0
2Ks6MPS77mNLnpFCNQm9ExYxXTj17oeqLumadiW9b3qX2i7B0K0ARevzE+fkSwfX
jPyVpH6N5/i84ptP3miWZ3267nTtuPhwgWc3QD/EqxSP/kKOuQfAj5hfO5yyEG1C
MaZ4MX1HROJiJ5jElR3Ibl672ypuM5GsoSjBwneExmH0ebFk29kBB8t5gW9rvTP0
j/+9zPQJPIWcPlD9822nS8/uq0IGfa6jGYzp09bQ
-----END CERTIFICATE-----
''';

const _testKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCfusWfK3gvYSKq
DrjH9+zpovuMzK1pE2RUbAB6O1sZIvPr+4+ldWu8HOe9LLOIZXzHEl56yDGh9o3J
I+sw1S2QPoHfoIWcMYhOb4uEvLN7pV1ohYDQhcZbYaUJC+A+7VWVVQX0wQmrl6Rg
yd7J0lrU13BEG7Tv65qCd9cg5Feke5Vfxtzf63bTOL2z0VVbuKvMDqZk5s33wWOV
mTsVzGNZE3XorxxjO3D/oMqWDLIJuYCaSvWQAv7XHKhsk/yjupmuPYcOB7ZAM5PK
m/782SIpEL3GXGRu+N0+mH2DHhZXOxcqZ+eyLmyMgY6ZDSY9f646E6dhCDj4ejgW
Q2X9LZ4zAgMBAAECggEABV7WwSzJfDJUY4peLR8JYKuhsJC7LeLAh1QgSfvP6s7x
i5goMsR5bFg+dG5Z1PawlNLpyVAM1yi+iKpEAJ7SStzHKhkwFNnXfueiNcLQeBJN
yzNd6uTsj+r/DQhQsFzzeTNkIWASLqpJFRYEfx2q/ygFNs0FruFpjwRvf8QdrEKL
39Gk3LgU7nZpTZXwgjSufo3RNgyDNt9qV5v3lMvJIY+hwcobBOqDXGdDBwfvNvJJ
GgI+X3I0Q+ioMymJ38uoYu3bgwWU3PwZ5C2rtzLZz4j7EjVQ6CDfLPKzYiy/FpwA
Z3ZIAuv/DV6hohsRUax/LwgcZfnuSaGF9lxuksVhpQKBgQDOgQ5uYmZq+T32AmvQ
TAj0mUmCGBAvTRN50BIwHnWaJOG85SPUfBpF6rKq0DYPFoNFRXtwVL+etckH382m
T3Hza3Q6JE2uItYZs6i4bqN+XsdCkI1ykZVuwjvsGPgTCNRxAS5fFLLa+IY6dbo5
K1adg0ApAkl9W6E6tfDfdltFJwKBgQDGA6nFo+xerowH4dCgLBHr6odcqZTGH2yJ
oXnkevwsyXQU+n+CzZEEK+tYBwTnveLAcCFwtDJFzXRgf4+N/4cTDV+zZY/9Aw4G
ZrMoP32citHOBhJuajkMkWeCJs7KR3pW/Umgo/zg8Zm89jkkomr0iZkuFJWw6sR5
LZ9iqXK+FQKBgQCOUOcPMAWBh9Ap8TU4Uo6Bc/rzC35r+uSHONywCO3nk693LTvq
PrUkpkEH84KuF0fUv7P4kI+W45VuNdFW4r2XkuCBCW/3qM6A3A5VPPq0JsGQoGq7
IJYpxPbjGbot9BHk53l70ZoJyulG9MeoirOgzkmzeX4IRNPy0Fz2xGzWVQKBgQC1
pnyjE7ruLN/HB1AU7/jM3Iyq4+LYUdGG/LxObshR6cj0ycwZ2az0D7pJOb81PMv8
T6FNu/D2egEN2Vd/I2/teXJWp5AMwjWmh6ZJAN2hsvO/NXDJG+cT8XvsON+xTxsb
HCbkGCwOy3SGlbZcNic6B9SfIkEkWGo+5Cx4HQxm9QKBgBn87zZjpdBKjs49FSXr
ebaSdPAzhoPHiTgVqK371KuY9FhZYYb1tEzfZMM4qGtLiASyuCOchMlmnhDJnI0a
EdOnZgCWDh5vXZldcNRDL5dcRTK2D7lcfKUhmtMzh1bhzAbxt5OVsKGwv2tfwc4g
pVGCJzFWVlH7ATwiaVqsssae
-----END PRIVATE KEY-----
''';

SecurityContext _buildTestContext() {
  final ctx = SecurityContext();
  ctx.useCertificateChainBytes(_testCert.codeUnits);
  ctx.usePrivateKeyBytes(_testKey.codeUnits);
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

    setUp(() {
      app = Fletch(secureCookies: false, requestTimeout: null);
      app.get('/ping', (req, res) => res.text('pong'));
    });

    tearDown(() async {
      await app.close();
      await server.close(force: true);
    });

    test('binds on IPv4 loopback and serves HTTPS requests', () async {
      final ctx = _buildTestContext();
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
      final ctx = _buildTestContext();
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
      final ctx = _buildTestContext();
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
