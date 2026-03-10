import 'package:fletch/fletch.dart';

// Named top-level handler — VM updates this in-place on hot reload
void rootHandler(req, res) {
  res.json({
    'message': 'Hello - HOT RELOADED!',
    'version': '2.0',
    'timestamp': DateTime.now().toIso8601String(),
  });
}

void registerRoutes(Fletch app) {
  app.get('/', rootHandler);

  app.get('/health', (req, res) {
    res.json({'status': 'ok'});
  });

  app.get('/user/:id', (req, res) {
    final id = req.params['id'];
    res.json({'id': id, 'name': 'User $id'});
  });
}
