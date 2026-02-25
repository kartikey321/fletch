/// Benchmark server — dart:io HttpServer transport.
///
/// Usage: dart run bin/server_dart_io.dart [port]
///
/// Prints "READY port=<n>" once listening so that bench.sh knows it is up.
import 'dart:io';

import 'package:fletch/fletch.dart';

void main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;

  final app = Fletch(secureCookies: false);

  app.get('/bench', (req, res) {
    res.json({'transport': 'dart:io', 'ok': true});
  });

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  await app.serveWith(server);

  // Signal to bench.sh that the server is up.
  // Flush explicitly — stdout is block-buffered when redirected to a file.
  stdout.writeln('READY port=${server.port}');
  await stdout.flush();
}
