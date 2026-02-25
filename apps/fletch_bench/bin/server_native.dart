/// Benchmark server — server_native (Rust-backed) transport.
///
/// Usage: dart run bin/server_native.dart [port]
///
/// Prints "READY port=<n>" once listening so that bench.sh knows it is up.
import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:server_native/server_native.dart';

void main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;

  final app = Fletch(secureCookies: false);

  app.get('/bench', (req, res) {
    res.json({'transport': 'native', 'ok': true});
  });

  // NativeHttpServer implements HttpServer, so serveWith() accepts it directly.
  final server = await NativeHttpServer.bind(InternetAddress.anyIPv4, port);
  await app.serveWith(server);

  stdout.writeln('READY port=${server.port}');
  await stdout.flush();
}
