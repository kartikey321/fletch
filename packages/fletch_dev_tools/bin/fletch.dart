#!/usr/bin/env dart

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fletch_dev_tools/fletch_dev_tools.dart';

/// Candidate entry points to probe when --entry is not specified.
const _candidateEntryPoints = [
  'bin/main.dart',
  'bin/server.dart',
  'bin/app.dart',
];

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('entry',
        abbr: 'e', help: 'Entry point file (auto-detected if omitted)')
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

  final port = int.parse(results['port'] as String);
  final watchDirs = results['watch'] as List<String>;

  // Resolve entry point: explicit flag → auto-detect → error
  final entryPoint = _resolveEntryPoint(results['entry'] as String?);
  if (entryPoint == null) {
    print('❌ Could not find an entry point. Tried:');
    for (final c in _candidateEntryPoints) {
      print('   • $c');
    }
    print('\nSpecify one with: fletch dev --entry bin/your_server.dart');
    exit(1);
  }

  final devServer = FletchDevServer(
    entryPoint: entryPoint,
    port: port,
    watchDirectories: watchDirs,
  );

  Future<void> shutdown() async {
    print('\n\n👋 Shutting down...');
    await devServer.stop();
    exit(0);
  }

  // Handle both Ctrl+C (SIGINT) and process termination (SIGTERM)
  ProcessSignal.sigint.watch().listen((_) => shutdown());
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown());
  }

  try {
    await devServer.start();
    // Keep running until a signal fires
    await Completer<void>().future;
  } catch (e) {
    print('❌ Error: $e');
    await devServer.stop();
    exit(1);
  }
}

/// Returns the resolved entry point path, or null if nothing was found.
String? _resolveEntryPoint(String? explicit) {
  if (explicit != null) {
    if (File(explicit).existsSync()) return explicit;
    print('❌ Entry point not found: $explicit');
    exit(1);
  }

  for (final candidate in _candidateEntryPoints) {
    if (File(candidate).existsSync()) {
      print('🔍 Auto-detected entry point: $candidate');
      return candidate;
    }
  }
  return null;
}

void _printUsage(ArgParser parser) {
  print('Fletch Development Server');
  print('');
  print('Usage: fletch dev [options]');
  print('');
  print('Options:');
  print(parser.usage);
  print('');
  print('Examples:');
  print('  fletch dev');
  print('  fletch dev --entry bin/server.dart --port 8080');
  print('  fletch dev --watch lib,routes,controllers');
}
