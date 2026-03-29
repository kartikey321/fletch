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
    ..addFlag(
      'verbose-compiler',
      negatable: false,
      help: 'Show verbose incremental compiler protocol and diagnostics',
    )
    ..addOption(
      'compiler-max-recovery-attempts',
      defaultsTo: '1',
      help: 'Incremental compiler daemon recovery retries (>= 0)',
    )
    ..addOption(
      'compiler-max-diagnostics',
      defaultsTo: '80',
      help: 'Max compiler diagnostics lines in normal mode (> 0)',
    )
    ..addOption(
      'compiler-recovery-backoff-ms',
      defaultsTo: '120',
      help: 'Base backoff in ms between compiler recovery attempts (>= 0)',
    )
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
  final verboseCompiler = results['verbose-compiler'] as bool;
  final compilerMaxRecoveryAttempts = _parseIntOption(
    results,
    optionName: 'compiler-max-recovery-attempts',
    min: 0,
  );
  final compilerMaxDiagnostics = _parseIntOption(
    results,
    optionName: 'compiler-max-diagnostics',
    min: 1,
  );
  final compilerRecoveryBackoffMs = _parseIntOption(
    results,
    optionName: 'compiler-recovery-backoff-ms',
    min: 0,
  );

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
    verboseCompiler: verboseCompiler,
    compilerMaxDiagnostics: compilerMaxDiagnostics,
    compilerMaxRecoveryAttempts: compilerMaxRecoveryAttempts,
    compilerRecoveryBackoff: Duration(milliseconds: compilerRecoveryBackoffMs),
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
  print('  fletch dev --verbose-compiler');
  print('  fletch dev --compiler-max-recovery-attempts 2');
  print('  fletch dev --compiler-max-diagnostics 120');
  print('  fletch dev --compiler-recovery-backoff-ms 250');
}

int _parseIntOption(
  ArgResults results, {
  required String optionName,
  required int min,
}) {
  final raw = results[optionName] as String;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < min) {
    print(
      "❌ Invalid value for --$optionName: '$raw' (expected integer >= $min)",
    );
    exit(1);
  }
  return parsed;
}
