import 'dart:io';
import 'package:fletch_dev_tools/src/ast_change_analyzer.dart';

/// Focused test for method body-only changes (THE KEY TEST!)
Future<void> main() async {
  print('🎯 Method Body-Only Detection Test\n');

  final analyzer = ASTChangeAnalyzer();
  final testFile = 'method_body_test.dart';

  // Version 1: Initial code
  print('📝 Creating initial version...\n');
  await _createFile(testFile, 1);
  await analyzer.analyzeFile(testFile); // Cache AST

  print('━' * 60);
  print('\n✅ TEST 1: Pure Method Body Change (Should be SAFE!)\n');
  await _createFile(testFile, 2);
  await _printResults(analyzer, testFile);

  print('━' * 60);
  print('\n⚠️  TEST 2: Method Signature Change (Should require restart)\n');
  await _createFile(testFile, 3);
  await _printResults(analyzer, testFile);

  print('━' * 60);
  print('\n✅ TEST 3: Multiple Method Bodies Changed (Should be SAFE!)\n');
  await _createFile(testFile, 4);
  await _printResults(analyzer, testFile);

  // Cleanup
  await File(testFile).delete();
  print('\n✨ Tests complete!\n');
}

Future<void> _printResults(ASTChangeAnalyzer analyzer, String file) async {
  final changes = await analyzer.analyzeFile(file);

  if (changes.isEmpty) {
    print('  ℹ️  No changes detected\n');
    return;
  }

  print('  Changes detected:\n');
  for (final change in changes) {
    print('    $change');
    if (change.suggestion != null) {
      print('      💡 ${change.suggestion}');
    }
  }

  final safeCount = changes.where((c) => c.isSafeForHotReload).length;
  final unsafeCount = changes.where((c) => c.requiresRestart).length;

  print('');
  print('  📊 Summary:');
  print('     ✅ Safe for hot reload: $safeCount');
  print('     ⚠️  Requires restart: $unsafeCount');

  if (unsafeCount > 0) {
    print('  \n  🔄 Decision: HOT RESTART required');
  } else if (safeCount > 0) {
    print('  \n  🔥 Decision: HOT RELOAD possible!');
  }
  print('');
}

Future<void> _createFile(String path, int version) async {
  String content;

  switch (version) {
    case 1:
      // Initial version
      content = '''
class Calculator {
  int add(int a, int b) {
    return a + b;
  }
  
  int multiply(int x, int y) {
    return x * y;
  }
}

String formatName(String name) {
  return name.toUpperCase();
}
''';
      break;

    case 2:
      // Version 2: ONLY method bodies changed
      content = '''
class Calculator {
  int add(int a, int b) {
    print('Adding \$a and \$b');  // ADDED LINE
    return a + b;
  }
  
  int multiply(int x, int y) {
    final result = x * y;  // CHANGED IMPLEMENTATION
    print('Result: \$result');  // ADDED LINE
    return result;
  }
}

String formatName(String name) {
  return name.trim().toUpperCase();  // CHANGED BODY
}
''';
      break;

    case 3:
      // Version 3: Signature changed (breaking!)
      content = '''
class Calculator {
  int add(int a, int b, {bool verbose = false}) {  // ADDED PARAMETER!
    print('Adding \$a and \$b');
    return a + b;
  }
  
  int multiply(int x, int y) {
    final result = x * y;
    print('Result: \$result');
    return result;
  }
}

String formatName(String name, {String prefix = ''}) {  // ADDED PARAMETER!
  return prefix + name.trim().toUpperCase();
}
''';
      break;

    case 4:
      // Version 4: Multiple body changes (all safe!)
      content = '''
class Calculator {
  int add(int a, int b, {bool verbose = false}) {
    if (verbose) {
      print('Calculating \$a + \$b');  // CHANGED BODY
    }
    return a + b;
  }
  
  int multiply(int x, int y) {
    if (x == 0 || y == 0) {  // ADDED LOGIC
      return 0;
    }
    final result = x * y;
    print('Multiplication result: \$result');  // CHANGED
    return result;
  }
}

String formatName(String name, {String prefix = ''}) {
  final trimmed = name.trim();  // CHANGED IMPLEMENTATION
  final upper = trimmed.toUpperCase();
  return prefix.isEmpty ? upper : '\$prefix: \$upper';
}
''';
      break;

    default:
      content = '';
  }

  await File(path).writeAsString(content);
}
