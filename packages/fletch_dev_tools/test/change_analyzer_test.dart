import 'dart:io';

import 'package:fletch_dev_tools/src/change_analyzer.dart';
import 'package:test/test.dart';

void main() {
  late ChangeAnalyzer analyzer;
  late Directory tempDir;

  setUp(() async {
    analyzer = ChangeAnalyzer();
    tempDir = await Directory.systemTemp.createTemp('fletch_ca_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ─── helpers ───────────────────────────────────────────────────────────────

  Future<File> createFile(String relativePath, String content) async {
    final file = File('${tempDir.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  // ─── quick-fail rules (no AST needed) ─────────────────────────────────────

  group('quick-fail rules', () {
    test('pubspec.yaml always requires restart', () async {
      final f = await createFile('pubspec.yaml', 'name: test');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.requiresRestart);
      expect(result.reason, contains('Dependencies'));
    });

    test('.g.dart always requires restart', () async {
      final f = await createFile('lib/models.g.dart', '// generated');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.requiresRestart);
      expect(result.reason, contains('Generated'));
    });

    test('file inside bin/ always requires restart', () async {
      final f = await createFile('bin/server.dart', 'void main() {}');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.requiresRestart);
      expect(result.reason, contains('Entry point'));
    });

    test('file named main.dart always requires restart', () async {
      final f = await createFile('lib/main.dart', 'void main() {}');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.requiresRestart);
      expect(result.reason, contains('Entry point'));
    });

    test('lib/domain_main_utils.dart does NOT match main.dart rule', () async {
      // "main" in the name but not exactly main.dart
      final f = await createFile(
        'lib/domain_main_utils.dart',
        'String formatDomain(String s) => s.toLowerCase();',
      );
      // First call caches — no changes yet
      final first = await analyzer.analyze(f.path);
      expect(first.decision, ReloadDecision.requiresRestart); // default safe

      // Modify body and reanalyze
      await f.writeAsString('String formatDomain(String s) => s.toUpperCase();');
      final second = await analyzer.analyze(f.path);
      expect(second.decision, ReloadDecision.canHotReload);
    });

    test('lib/bin_utils.dart does NOT match bin/ rule', () async {
      // "bin" in the name but not in a bin/ segment
      const src = 'int decode(List<int> bytes) => bytes.length;';
      final f = await createFile('lib/bin_utils.dart', src);
      await analyzer.analyze(f.path); // cache

      await f.writeAsString('int decode(List<int> bytes) { return bytes.length; }');
      final result = await analyzer.analyze(f.path);
      expect(result.decision, ReloadDecision.canHotReload);
    });
  });

  // ─── non-dart files ────────────────────────────────────────────────────────

  group('non-dart files', () {
    test('changing a .yaml file (not pubspec) defaults to requiresRestart',
        () async {
      final f = await createFile('config/routes.yaml', 'foo: bar');
      final result = await analyzer.analyze(f.path);
      expect(result.decision, ReloadDecision.requiresRestart);
    });

    test('changing a .json file defaults to requiresRestart', () async {
      final f = await createFile('assets/data.json', '{}');
      final result = await analyzer.analyze(f.path);
      expect(result.decision, ReloadDecision.requiresRestart);
    });
  });

  // ─── dart files with AST analysis ─────────────────────────────────────────

  group('dart file analysis', () {
    test('body-only change → canHotReload', () async {
      final f = await createFile('lib/handlers.dart', '''
String handle(String input) {
  return input;
}
''');
      await analyzer.analyze(f.path); // prime cache

      await f.writeAsString('''
String handle(String input) {
  return input.trim();
}
''');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.canHotReload);
      expect(result.changes, isNotEmpty);
      expect(result.changes.every((c) => c.isSafeForHotReload), isTrue);
    });

    test('signature change → requiresRestart', () async {
      final f = await createFile('lib/handlers.dart', '''
String handle(String input) => input;
''');
      await analyzer.analyze(f.path);

      await f.writeAsString('''
String handle(String input, {bool trim = false}) => input;
''');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.requiresRestart);
      expect(result.changes.any((c) => c.requiresRestart), isTrue);
      expect(result.reason, isNotEmpty);
    });

    test('global variable change → requiresRestart', () async {
      final f = await createFile('lib/config.dart', '''
final appName = 'MyApp';
''');
      await analyzer.analyze(f.path);

      await f.writeAsString('''
final appName = 'MyApp';
final version = '1.0.0';
''');
      final result = await analyzer.analyze(f.path);

      expect(result.decision, ReloadDecision.requiresRestart);
    });

    test('first analysis (cold cache) defaults to requiresRestart', () async {
      final f = await createFile('lib/fresh.dart', '''
void doSomething() => print('hi');
''');
      // No prior analyze call — cold cache
      final result = await analyzer.analyze(f.path);
      // No changes detected (nothing to diff) → falls through to default
      expect(result.decision, ReloadDecision.requiresRestart);
    });
  });

  // ─── AnalysisResult structure ──────────────────────────────────────────────

  group('AnalysisResult', () {
    test('changes list is populated on body change', () async {
      final f = await createFile('lib/service.dart', '''
void process() { print('v1'); }
''');
      await analyzer.analyze(f.path);

      await f.writeAsString('''
void process() { print('v2'); }
''');
      final result = await analyzer.analyze(f.path);

      expect(result.changes, isNotEmpty);
      expect(result.reason, isNotEmpty);
    });

    test('changes list is empty for quick-fail paths', () async {
      final f = await createFile('pubspec.yaml', 'name: test');
      final result = await analyzer.analyze(f.path);

      expect(result.changes, isEmpty);
      expect(result.decision, ReloadDecision.requiresRestart);
    });
  });
}
