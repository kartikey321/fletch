import 'package:fletch/fletch.dart';
import 'dart:io';

void main() async {
  final app = Fletch();

  // Simple route for testing hot reload
  app.get('/', (req, res) {
    res.json({
      'message': 'Hello from Fletch - hot reloaded!',
      'version': '2.0',
      'timestamp': DateTime.now().toIso8601String(),
    });
  });

  // Health check
  app.get('/health', (req, res) {
    res.json({'status': 'ok'});
  });

  // User route
  app.get('/user/:id', (req, res) {
    final id = req.params['id'];
    res.json({
      'id': id,
      'name': 'User $id',
    });
  });

  // Start server
  final port = int.parse(Platform.environment['PORT'] ?? '3003');
  await app.listen(port);
  print('Test server running on http://localhost:$port');
}
