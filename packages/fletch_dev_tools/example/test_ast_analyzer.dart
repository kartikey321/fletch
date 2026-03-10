import 'dart:io';
import 'package:fletch_dev_tools/src/ast_change_analyzer.dart';

/// Test script to demonstrate AST-based change detection.
Future<void> main() async {
  print('🔬 AST Change Detection Test\n');
  
  final analyzer = ASTChangeAnalyzer();
  final testFile = 'test_sample.dart';
  
  // Create test file
  await _createTestFile(testFile, version: 1);
  print('📝 Created test file (version 1)\n');
  
  // First analysis (caches AST)
  await analyzer.analyzeFile(testFile);
  print('✅ Initial AST cached\n');
  
  print('━' * 50);
  print('\n🧪 TEST 1: Method Body Change (Safe)\n');
  await _createTestFile(testFile, version: 2);
  await _printChanges(analyzer, testFile);
  
  print('━' * 50);
  print('\n🧪 TEST 2: Add Class Field (Structural)\n');
  await _createTestFile(testFile, version: 3);
  await _printChanges(analyzer, testFile);
  
  print('━' * 50);
  print('\n🧪 TEST 3: Change Main Function (Requires Restart)\n');
  await _createTestFile(testFile, version: 4);
  await _printChanges(analyzer, testFile);
  
  print('━' * 50);
  print('\n🧪 TEST 4: Global Variable (Requires Restart)\n');
  await _createTestFile(testFile, version: 5);
  await _printChanges(analyzer, testFile);
  
  // Cleanup
  await File(testFile).delete();
  print('\n✅ Tests complete!\n');
}

Future<void> _printChanges(ASTChangeAnalyzer analyzer, String file) async {
  final changes = await analyzer.analyzeFile(file);
  
  if (changes.isEmpty) {
    print('  No changes detected\n');
    return;
  }
  
  for (final change in changes) {
    print('  $change');
    if (change.suggestion != null) {
      print('     💡 ${change.suggestion}');
    }
  }
  
  final safeCount = changes.where((c) => c.isSafeForHotReload).length;
  final unsafeCount = changes.where((c) => c.requiresRestart).length;
  
  print('');
  print('  Summary: $safeCount safe, $unsafeCount requires restart');
  
  if (unsafeCount > 0) {
    print('  Decision: ⚠️  HOT RESTART required');
  } else {
    print('  Decision: ✅ HOT RELOAD possible');
  }
  print('');
}

Future<void> _createTestFile(String path, {required int version}) async {
  String content;
  
  switch (version) {
    case 1:
      // Initial version
      content = '''
class User {
  String name;
  
  User(this.name);
  
  String greet() {
    return 'Hello, \$name!';
  }
}

void main() {
  final user = User('Alice');
  print(user.greet());
}

final config = {'debug': true};
''';
      break;
    
    case 2:
      // Version 2: Method body change (SAFE)
      content = '''
class User {
  String name;
  
  User(this.name);
  
  String greet() {
    return 'Hi, \$name! Welcome!'; // CHANGED
  }
}

void main() {
  final user = User('Alice');
  print(user.greet());
}

final config = {'debug': true};
''';
      break;
    
    case 3:
      // Version 3: Add field (STRUCTURAL)
      content = '''
class User {
  String name;
  String email; // NEW FIELD - STRUCTURAL CHANGE!
  
  User(this.name, this.email); // CHANGED CONSTRUCTOR
  
  String greet() {
    return 'Hi, \$name! Welcome!';
  }
}

void main() {
  final user = User('Alice', 'alice@example.com');
  print(user.greet());
}

final config = {'debug': true};
''';
      break;
    
    case 4:
      // Version 4: Change main (REQUIRES RESTART)
      content = '''
class User {
  String name;
  String email;
  
  User(this.name, this.email);
  
  String greet() {
    return 'Hi, \$name! Welcome!';
  }
}

void main() {
  print('App starting...'); // CHANGED MAIN
  final user = User('Alice', 'alice@example.com');
  print(user.greet());
}

final config = {'debug': true};
''';
      break;
    
    case 5:
      // Version 5: Change global (REQUIRES RESTART)
      content = '''
class User {
  String name;
  String email;
  
  User(this.name, this.email);
  
  String greet() {
    return 'Hi, \$name! Welcome!';
  }
}

void main() {
  print('App starting...');
  final user = User('Alice', 'alice@example.com');
  print(user.greet());
}

final config = {'debug': false}; // CHANGED GLOBAL
''';
      break;
    
    default:
      content = '';
  }
  
  await File(path).writeAsString(content);
}
