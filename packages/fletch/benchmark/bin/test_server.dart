import 'package:fletch/fletch.dart';

/// Simple benchmark server for load testing
///
/// This server has minimal overhead to showcase framework performance
void main() async {
  final app = Fletch(
    sessionSecret: 'benchmark-server-secret-key-min-32',
    secureCookies: false,
  );

  // Simple JSON endpoint
  app.get('/', (req, res) {
    res.json({'message': 'Hello, Benchmark!'});
  });

  // Echo endpoint
  app.get('/echo/:message', (req, res) {
    res.json({'echo': req.params['message']});
  });

  // Session test endpoint
  app.get('/counter', (req, res) {
    final count = req.session['count'] ?? 0;
    req.session['count'] = count + 1;
    res.json({'count': count + 1});
  });

  // Health check
  app.get('/health', (req, res) {
    res.json(
        {'status': 'healthy', 'timestamp': DateTime.now().toIso8601String()});
  });

  await app.listen(3008);
  print('🚀 Benchmark server running on http://localhost:3008');
  print('');
  print('Available endpoints:');
  print('  GET  /           - Simple hello message');
  print('  GET  /echo/:msg  - Echo parameter');
  print('  GET  /counter    - Session counter');
  print('  GET  /health     - Health check');
  print('');
  print('Test with:');
  print('  dart run bin/load_test.dart http://localhost:3008 1000 10');
}

