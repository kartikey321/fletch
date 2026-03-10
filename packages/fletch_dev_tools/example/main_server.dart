import 'dart:io';
import 'package:fletch/fletch.dart';
import 'lib/handlers.dart';

void main() async {
  final app = Fletch();
  // Register the route factory so dev tools can reassemble routes after
  // each hot reload without restarting the server process.
  app.hotReload(() => registerRoutes(app));
  registerRoutes(app);
  final port = int.parse(Platform.environment['PORT'] ?? '3005');
  await app.listen(port);
  print('Server running on http://localhost:$port');
}
