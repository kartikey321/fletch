import 'dart:async';
import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:fletch_dev_tools/fletch_dev_tools.dart';

final List<Completer<void>> _pendingSlowRequests = <Completer<void>>[];

void _registerRoutes(Fletch app) {
  app.get('/ping', (req, res) => res.text('ok'));

  app.get('/slow', (req, res) async {
    final completer = Completer<void>();
    _pendingSlowRequests.add(completer);
    await completer.future;
    res.text('slow-done');
  });

  app.post('/release', (req, res) {
    if (_pendingSlowRequests.isNotEmpty) {
      final next = _pendingSlowRequests.removeAt(0);
      if (!next.isCompleted) {
        next.complete();
      }
      res.text('released');
      return;
    }
    res.text('none');
  });
}

Future<void> main() async {
  final app = Fletch(
    secureCookies: false,
    requestTimeout: const Duration(seconds: 8),
    shutdownTimeout: const Duration(seconds: 4),
  );
  configureDevHotReload(
    app,
    registerRoutes: () => _registerRoutes(app),
    enabled: true,
  );

  final requestedPort = int.tryParse(Platform.environment['PORT'] ?? '') ?? 0;
  await app.listen(
    requestedPort == 0 ? 0 : requestedPort,
    address: InternetAddress.loopbackIPv4,
  );
}
