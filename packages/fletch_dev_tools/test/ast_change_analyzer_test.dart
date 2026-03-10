import 'dart:io';

import 'package:fletch_dev_tools/src/ast_change_analyzer.dart';
import 'package:test/test.dart';

void main() {
  late ASTChangeAnalyzer analyzer;
  late Directory tempDir;
  late File testFile;

  setUp(() async {
    analyzer = ASTChangeAnalyzer();
    tempDir = await Directory.systemTemp.createTemp('fletch_ast_test_');
    testFile = File('${tempDir.path}/subject.dart');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ─── helpers ───────────────────────────────────────────────────────────────

  Future<void> write(String content) => testFile.writeAsString(content);

  Future<List<CodeChange>> analyze() => analyzer.analyzeFile(testFile.path);

  // ─── first-time analysis ───────────────────────────────────────────────────

  group('first analysis (no cached AST)', () {
    test('returns empty list — nothing to diff against', () async {
      await write('''
void greet() {
  print('hello');
}
''');
      final changes = await analyze();
      expect(changes, isEmpty);
    });
  });

  // ─── no-op (unchanged file) ────────────────────────────────────────────────

  group('unchanged file', () {
    test('returns empty list when content is identical', () async {
      const src = '''
void greet() {
  print('hello');
}
''';
      await write(src);
      await analyze(); // cache

      await write(src);
      final changes = await analyze();
      expect(changes, isEmpty);
    });
  });

  // ─── body-only changes ─────────────────────────────────────────────────────

  group('body-only changes', () {
    test('top-level function body change is safe for hot reload', () async {
      await write('''
String greet(String name) {
  return 'Hello, \$name';
}
''');
      await analyze();

      await write('''
String greet(String name) {
  return 'Hi there, \$name!';
}
''');
      final changes = await analyze();

      expect(changes, isNotEmpty);
      expect(changes.every((c) => c.isSafeForHotReload), isTrue);
      expect(
        changes.any((c) => c.category == ChangeCategory.methodBodyOnly),
        isTrue,
      );
    });

    test('multiple function body changes are all safe', () async {
      await write('''
int add(int a, int b) => a + b;
int multiply(int a, int b) => a * b;
''');
      await analyze();

      await write('''
int add(int a, int b) {
  print('adding');
  return a + b;
}
int multiply(int a, int b) {
  print('multiplying');
  return a * b;
}
''');
      final changes = await analyze();

      expect(changes, isNotEmpty);
      expect(changes.every((c) => c.isSafeForHotReload), isTrue);
    });
  });

  // ─── signature changes ─────────────────────────────────────────────────────

  group('signature changes', () {
    test('adding a parameter is a breaking change', () async {
      await write('''
void log(String message) {
  print(message);
}
''');
      await analyze();

      await write('''
void log(String message, {bool verbose = false}) {
  print(message);
}
''');
      final changes = await analyze();

      expect(changes.any((c) => c.requiresRestart), isTrue);
      expect(
        changes.any((c) => c.category == ChangeCategory.breakingChange),
        isTrue,
      );
    });

    test('changing return type is a breaking change', () async {
      await write('''
String getName() => 'Alice';
''');
      await analyze();

      await write('''
dynamic getName() => 'Alice';
''');
      final changes = await analyze();

      expect(changes.any((c) => c.requiresRestart), isTrue);
    });

    test('removing a function is a breaking change', () async {
      await write('''
void foo() {}
void bar() {}
''');
      await analyze();

      await write('''
void foo() {}
''');
      final changes = await analyze();

      expect(changes.any((c) => c.category == ChangeCategory.breakingChange),
          isTrue);
    });
  });

  // ─── structural changes ────────────────────────────────────────────────────

  group('class structural changes', () {
    test('adding a field is a structural change', () async {
      await write('''
class User {
  String name;
  User(this.name);
}
''');
      await analyze();

      await write('''
class User {
  String name;
  String email;
  User(this.name, this.email);
}
''');
      final changes = await analyze();

      expect(changes.any((c) => c.requiresRestart), isTrue);
      expect(
        changes.any((c) => c.category == ChangeCategory.structuralChange),
        isTrue,
      );
    });

    test('adding a method is a structural change', () async {
      await write('''
class Greeter {
  String greet() => 'Hello';
}
''');
      await analyze();

      await write('''
class Greeter {
  String greet() => 'Hello';
  String farewell() => 'Goodbye';
}
''');
      final changes = await analyze();

      expect(changes.any((c) => c.requiresRestart), isTrue);
    });

    test('adding a new class is a structural change', () async {
      await write('''
class A {}
''');
      await analyze();

      await write('''
class A {}
class B {}
''');
      final changes = await analyze();

      expect(
        changes.any((c) => c.category == ChangeCategory.structuralChange),
        isTrue,
      );
    });

    test('removing a class is a breaking change', () async {
      await write('''
class A {}
class B {}
''');
      await analyze();

      await write('''
class A {}
''');
      final changes = await analyze();

      expect(changes.any((c) => c.requiresRestart), isTrue);
    });
  });

  // ─── global variable changes ───────────────────────────────────────────────

  group('global variable changes', () {
    test('adding a global variable requires restart', () async {
      await write('''
final config = <String, dynamic>{};
''');
      await analyze();

      await write('''
final config = <String, dynamic>{};
final debug = true;
''');
      final changes = await analyze();

      expect(
        changes.any((c) => c.category == ChangeCategory.globalChange),
        isTrue,
      );
      expect(changes.any((c) => c.requiresRestart), isTrue);
    });

    test('removing a global variable requires restart', () async {
      await write('''
final config = <String, dynamic>{};
final debug = true;
''');
      await analyze();

      await write('''
final config = <String, dynamic>{};
''');
      final changes = await analyze();

      expect(changes.any((c) => c.requiresRestart), isTrue);
    });
  });

  // ─── main function changes ─────────────────────────────────────────────────

  group('main function changes', () {
    test('changing main() body requires restart', () async {
      await write('''
void main() {
  print('v1');
}
''');
      await analyze();

      await write('''
void main() {
  print('v2');
}
''');
      final changes = await analyze();

      expect(
        changes.any((c) => c.category == ChangeCategory.mainFunctionChange),
        isTrue,
      );
      expect(changes.any((c) => c.requiresRestart), isTrue);
    });
  });

  // ─── parse errors ──────────────────────────────────────────────────────────

  group('parse errors', () {
    test('returns empty list for syntactically invalid Dart', () async {
      await write('''
void greet() { print('hello'); }
''');
      await analyze();

      await write('''
void greet( {  // syntax error
''');
      final changes = await analyze();

      // Analyzer returns empty on parse failure — does not crash
      expect(changes, isEmpty);
    });
  });
}
