import 'dart:async';

import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Server lifecycle', () {
    TestServerHarness? harness;

    tearDown(() => harness?.dispose());

    test('waits for in-flight requests on close', () async {
      final app = Fletch(
        requestTimeout: const Duration(seconds: 2),
        shutdownTimeout: const Duration(seconds: 2),
      );
      harness = TestServerHarness(app: app);

      final started = Completer<void>();
      final completer = Completer<void>();
      harness!.app.get('/slow', (req, res) async {
        started.complete(); // handler entered; request is now in-flight
        await completer.future;
        res.text('done');
      });

      final responseFuture = harness!.get('/slow');
      await started.future;

      final closeFuture = harness!.app.close();

      completer.complete();

      final response = await responseFuture;
      await closeFuture;

      expect(response.statusCode, 200);
    });

    test('rejects new requests once shutdown starts', () async {
      final app = Fletch(shutdownTimeout: const Duration(seconds: 1));
      harness = TestServerHarness(app: app);
      await harness!.start();

      final slowCompleter = Completer<void>();
      harness!.app.get('/slow', (req, res) async {
        await slowCompleter.future;
        res.text('slow');
      });
      harness!.app.get('/ok', (req, res) => res.text('ok'));

      final slowFuture = harness!.get('/slow');
      final shuttingDown = harness!.app.close();
      await Future.delayed(const Duration(milliseconds: 25));
      final response = await harness!.get('/ok');

      expect(response.statusCode, 503);
      expect(response.body, contains('shutting down'));

      slowCompleter.complete();
      await slowFuture;
      await shuttingDown;
    });
  });
}
