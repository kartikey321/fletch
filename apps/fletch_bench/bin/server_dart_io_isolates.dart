/// Benchmark server — dart:io HttpServer, multi-isolate.
///
/// Spawns [Platform.numberOfProcessors] isolates all bound to the same port
/// via shared: true. The OS load-balances incoming connections across them.
///
/// Usage: dart run bin/server_dart_io_isolates.dart [port]
///
/// Prints "READY port=<n> workers=<n>" once all workers are listening.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:fletch/fletch.dart';

// ---------------------------------------------------------------------------
// Worker — runs in each spawned isolate.
// message: [port (int), readySendPort (SendPort)]
// ---------------------------------------------------------------------------
void _worker(List<dynamic> message) async {
  final port = message[0] as int;
  final readySend = message[1] as SendPort;

  final app = Fletch(secureCookies: false);
  app.get('/bench', (req, res) {
    res.json({'transport': 'dart:io-isolates', 'ok': true});
  });

  final server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
    shared: true,
  );

  readySend.send(null); // signal ready to main isolate
  await app.serveWith(server);
}

// ---------------------------------------------------------------------------
// Main isolate
// ---------------------------------------------------------------------------
void main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final totalWorkers = Platform.numberOfProcessors;
  final extraWorkers = totalWorkers - 1; // main isolate counts as one

  // Bind first to claim the ephemeral port (shared so others can join).
  final app = Fletch(secureCookies: false);
  app.get('/bench', (req, res) {
    res.json({'transport': 'dart:io-isolates', 'ok': true});
  });

  final server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
    shared: true,
  );

  // Spawn extra workers and wait for all to report ready.
  if (extraWorkers > 0) {
    final readyPort = ReceivePort();
    var readyCount = 0;
    final allReady = Completer<void>();

    readyPort.listen((_) {
      readyCount++;
      if (readyCount >= extraWorkers) {
        allReady.complete();
        readyPort.close();
      }
    });

    for (var i = 0; i < extraWorkers; i++) {
      await Isolate.spawn(_worker, [server.port, readyPort.sendPort]);
    }

    await allReady.future;
  }

  stdout.writeln('READY port=${server.port} workers=$totalWorkers');
  await stdout.flush();
  await app.serveWith(server);
}
