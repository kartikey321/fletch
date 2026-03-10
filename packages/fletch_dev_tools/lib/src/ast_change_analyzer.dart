import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Categories of code changes detected by AST analysis.
enum ChangeCategory {
  /// Method/function body changes only - safe for hot reload
  methodBodyOnly,

  /// Added/removed/modified class fields - requires restart
  structuralChange,

  /// Changed method signatures, renamed methods - requires restart
  breakingChange,

  /// Global variables, top-level constants - requires restart
  globalChange,

  /// Main function changes - requires restart
  mainFunctionChange,
}

/// Represents a detected code change.
class CodeChange {
  final ChangeCategory category;
  final String description;
  final String filePath;
  final int? line;
  final String? suggestion;

  CodeChange({
    required this.category,
    required this.description,
    required this.filePath,
    this.line,
    this.suggestion,
  });

  /// Whether this change is safe for hot reload.
  bool get isSafeForHotReload => category == ChangeCategory.methodBodyOnly;

  /// Whether this change requires a restart.
  bool get requiresRestart => !isSafeForHotReload;

  @override
  String toString() {
    final icon = isSafeForHotReload ? '✅' : '⚠️';
    final lineInfo = line != null ? ' [line $line]' : '';
    return '$icon $description$lineInfo';
  }
}

/// Analyzes Dart code changes using AST.
class ASTChangeAnalyzer {
  final Map<String, CompilationUnit> _astCache = {};

  /// Analyze a file for changes.
  Future<List<CodeChange>> analyzeFile(String filePath) async {
    final changes = <CodeChange>[];

    // Check if file exists
    if (!await File(filePath).exists()) {
      return changes;
    }

    // Parse current version
    final currentAst = await _parseFile(filePath);
    if (currentAst == null) return changes;

    // Get previous version from cache
    final previousAst = _astCache[filePath];

    if (previousAst == null) {
      // First time seeing this file - cache it
      _astCache[filePath] = currentAst;
      return changes;
    }

    // Compare ASTs
    changes.addAll(_compareASTs(previousAst, currentAst, filePath));

    // Update cache
    _astCache[filePath] = currentAst;

    return changes;
  }

  /// Parse a Dart file into AST.
  Future<CompilationUnit?> _parseFile(String filePath) async {
    try {
      final content = await File(filePath).readAsString();

      // Skip if file is empty — likely a transient truncation mid-write.
      if (content.trim().isEmpty) return null;

      final result = parseString(content: content);

      if (result.errors.isNotEmpty) {
        print('⚠️  Parse errors in $filePath:');
        for (final error in result.errors) {
          print('   - ${error.message}');
        }
        return null;
      }

      return result.unit;
    } catch (e) {
      print('❌ Failed to parse $filePath: $e');
      return null;
    }
  }

  /// Compare two ASTs and detect changes.
  List<CodeChange> _compareASTs(
    CompilationUnit oldAst,
    CompilationUnit newAst,
    String filePath,
  ) {
    final changes = <CodeChange>[];

    // Extract declarations
    final oldDecls = _ASTExtractor(oldAst).extract();
    final newDecls = _ASTExtractor(newAst).extract();

    // Compare classes
    changes
        .addAll(_compareClasses(oldDecls.classes, newDecls.classes, filePath));

    // Compare top-level functions
    changes.addAll(
        _compareFunctions(oldDecls.functions, newDecls.functions, filePath));

    // Compare globals
    changes
        .addAll(_compareGlobals(oldDecls.globals, newDecls.globals, filePath));

    return changes;
  }

  /// Compare class declarations.
  List<CodeChange> _compareClasses(
    Map<String, ClassInfo> oldClasses,
    Map<String, ClassInfo> newClasses,
    String filePath,
  ) {
    final changes = <CodeChange>[];

    // Check for added/removed classes
    for (final name in newClasses.keys) {
      if (!oldClasses.containsKey(name)) {
        changes.add(CodeChange(
          category: ChangeCategory.structuralChange,
          description: 'New class added: $name',
          filePath: filePath,
          suggestion: 'Restart required for new classes',
        ));
      }
    }

    // Check for modified classes
    for (final name in oldClasses.keys) {
      if (!newClasses.containsKey(name)) {
        changes.add(CodeChange(
          category: ChangeCategory.breakingChange,
          description: 'Class removed: $name',
          filePath: filePath,
          suggestion: 'Restart required - class deleted',
        ));
        continue;
      }

      final oldClass = oldClasses[name]!;
      final newClass = newClasses[name]!;

      // Check for field changes
      if (oldClass.fieldCount != newClass.fieldCount) {
        changes.add(CodeChange(
          category: ChangeCategory.structuralChange,
          description: 'Fields changed in class $name',
          filePath: filePath,
          suggestion: 'Restart required - instance structure changed',
        ));
      }

      // Check for method changes
      if (oldClass.methodCount != newClass.methodCount) {
        // Just method body changes might be safe
        // But adding/removing methods is structural
        changes.add(CodeChange(
          category: ChangeCategory.structuralChange,
          description: 'Methods changed in class $name',
          filePath: filePath,
        ));
      }
    }

    return changes;
  }

  /// Compare function declarations.
  List<CodeChange> _compareFunctions(
    Map<String, FunctionInfo> oldFunctions,
    Map<String, FunctionInfo> newFunctions,
    String filePath,
  ) {
    final changes = <CodeChange>[];

    // Check for added functions
    for (final name in newFunctions.keys) {
      if (!oldFunctions.containsKey(name)) {
        changes.add(CodeChange(
          category: ChangeCategory.methodBodyOnly,
          description: 'New function added: $name',
          filePath: filePath,
        ));
      }
    }

    // Check for removed/modified functions
    for (final name in oldFunctions.keys) {
      if (!newFunctions.containsKey(name)) {
        changes.add(CodeChange(
          category: ChangeCategory.breakingChange,
          description: 'Function removed: $name',
          filePath: filePath,
        ));
        continue;
      }

      final oldFunc = oldFunctions[name]!;
      final newFunc = newFunctions[name]!;

      // Check if main function changed
      if (name == 'main') {
        changes.add(CodeChange(
          category: ChangeCategory.mainFunctionChange,
          description: 'Main function changed',
          filePath: filePath,
          line: newFunc.line,
          suggestion: 'Restart required - main() only runs at startup',
        ));
        continue;
      }

      // Check for signature changes
      if (oldFunc.signature != newFunc.signature) {
        changes.add(CodeChange(
          category: ChangeCategory.breakingChange,
          description: 'Function signature changed: $name',
          filePath: filePath,
          line: newFunc.line,
          suggestion: 'Restart required - signature change is breaking',
        ));
      } else if (oldFunc.bodyHash != newFunc.bodyHash) {
        // Only body changed - SAFE for hot reload!
        changes.add(CodeChange(
          category: ChangeCategory.methodBodyOnly,
          description: 'Function body changed: $name',
          filePath: filePath,
          line: newFunc.line,
        ));
      }
    }

    return changes;
  }

  /// Compare global variables.
  List<CodeChange> _compareGlobals(
    Map<String, GlobalInfo> oldGlobals,
    Map<String, GlobalInfo> newGlobals,
    String filePath,
  ) {
    final changes = <CodeChange>[];

    if (oldGlobals.length != newGlobals.length ||
        !oldGlobals.keys.every(newGlobals.containsKey)) {
      changes.add(CodeChange(
        category: ChangeCategory.globalChange,
        description: 'Global variables changed',
        filePath: filePath,
        suggestion: 'Restart required - globals only initialize once',
      ));
    }

    return changes;
  }
}

/// Extracted AST information.
class _ASTDeclarations {
  final Map<String, ClassInfo> classes = {};
  final Map<String, FunctionInfo> functions = {};
  final Map<String, GlobalInfo> globals = {};
}

/// Class information.
class ClassInfo {
  final String name;
  final int fieldCount;
  final int methodCount;

  ClassInfo(this.name, this.fieldCount, this.methodCount);
}

/// Function information with signature and body hash.
class FunctionInfo {
  final String name;
  final String signature; // Full signature: returnType name(params)
  final String bodyHash; // Hash of method body for comparison
  final int? line; // Line number in source

  FunctionInfo(this.name, this.signature, this.bodyHash, this.line);
}

/// Global variable information.
class GlobalInfo {
  final String name;
  final bool isConst;

  GlobalInfo(this.name, this.isConst);
}

/// Visitor to extract declarations from AST.
class _ASTExtractor extends RecursiveAstVisitor<void> {
  final CompilationUnit ast;
  final _ASTDeclarations declarations = _ASTDeclarations();

  _ASTExtractor(this.ast);

  _ASTDeclarations extract() {
    ast.visitChildren(this);
    return declarations;
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final fields = node.members.whereType<FieldDeclaration>().length;
    final methods = node.members.whereType<MethodDeclaration>().length;

    declarations.classes[node.name.lexeme] = ClassInfo(
      node.name.lexeme,
      fields,
      methods,
    );

    super.visitClassDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final name = node.name.lexeme;
    final signature = _getFunctionSignature(node);
    final bodyHash = _getBodyHash(node.functionExpression.body);
    final line = node.offset;

    declarations.functions[name] = FunctionInfo(
      name,
      signature,
      bodyHash,
      line,
    );

    super.visitFunctionDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      declarations.globals[variable.name.lexeme] = GlobalInfo(
        variable.name.lexeme,
        node.variables.isConst,
      );
    }

    super.visitTopLevelVariableDeclaration(node);
  }

  /// Get function signature as string for comparison.
  String _getFunctionSignature(FunctionDeclaration node) {
    final buffer = StringBuffer();

    // Return type
    if (node.returnType != null) {
      buffer.write('${node.returnType} ');
    }

    // Function name
    buffer.write(node.name.lexeme);

    // Parameters
    final params = node.functionExpression.parameters;
    if (params != null) {
      buffer.write('(');
      final paramStrings = params.parameters.map((p) {
        if (p is SimpleFormalParameter) {
          return '${p.type} ${p.name}';
        } else if (p is FunctionTypedFormalParameter) {
          return '${p.returnType} ${p.name}(...)';
        } else if (p is DefaultFormalParameter) {
          return '${p.parameter}';
        }
        return p.toString();
      });
      buffer.write(paramStrings.join(', '));
      buffer.write(')');
    }

    return buffer.toString();
  }

  /// Get hash of function/method body for comparison.
  String _getBodyHash(FunctionBody body) {
    // Simple hash: just the body content as string
    // In production, could use better hashing (MD5, SHA)
    final bodyStr = body.toString().trim();
    return bodyStr.hashCode.toString();
  }
}
