#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:fletch/src/dev/dev_server.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('entry',
        abbr: 'e', defaultsTo: 'bin/main.dart', help: 'Entry point file')
    ..addOption('port', abbr: 'p', defaultsTo: '3003', help: 'Server port')
    ..addMultiOption('watch',
        abbr: 'w', defaultsTo: ['lib'], help: 'Directories to watch')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('Error: $e\n');
    _printUsage(parser);
    exit(1);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  final entryPoint = results['entry'] as String;
  final port = int.parse(results['port'] as String);
  final watchDirs = results['watch'] as List<String>;

  // Check if entry point exists
  if (!File(entryPoint).existsSync()) {
    print('❌ Entry point not found: $entryPoint');
    exit(1);
  }

  final devServer = FletchDevServer(
    entryPoint: entryPoint,
    port: port,
    watchDirectories: watchDirs,
  );

  // Handle Ctrl+C gracefully
  ProcessSignal.sigint.watch().listen((_) async {
    print('\n\n👋 Shutting down...');
    await devServer.stop();
    exit(0);
  });

  try {
    await devServer.start();

    // Keep running
    await Future.delayed(Duration(days: 365));
  } catch (e) {
    print('❌ Error: $e');
    await devServer.stop();
    exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('Fletch Development Server');
  print('');
  print('Usage: dart run fletch:dev [options]');
  print('');
  print('Options:');
  print(parser.usage);
  print('');
  print('Examples:');
  print('  dart run fletch:dev');
  print('  dart run fletch:dev --entry bin/server.dart --port 8080');
  print('  dart run fletch:dev --watch lib,routes');
}
