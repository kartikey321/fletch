// Fletch Dev Tools - Example Usage

import 'dart:io';

import 'package:fletch/fletch.dart';

Future<void> main() async {
  final app = Fletch();
  
  // Simple route
  app.get('/', (req, res) {
    res.json({'message': 'Hello from Fletch Dev Tools example!'});
  });
  
  // Health endpoint
  app.get('/health', (req, res) {
    res.json({'status': 'ok', 'timestamp': DateTime.now().toIso8601String()});
  });
  
  // Start server
  final port = int.parse(Platform.environment['PORT'] ?? '3000');
  await app.listen(port);
  print('Example server running on http://localhost:$port');
}
