import 'dart:io';

import 'package:fletch_dev_tools/src/reload_engine/classifier/dependency_graph.dart';
import 'package:test/test.dart';

void main() {
  group('DependencyGraphStore', () {
    test('expands invalidation to reverse import dependents', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'dep_graph_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final libDir = Directory('${tempDir.path}/lib/src')
        ..createSync(recursive: true);
      final apiFile = File('${libDir.path}/api.dart');
      final helperFile = File('${libDir.path}/helper.dart');

      apiFile.writeAsStringSync("import 'helper.dart';\nvoid api() {}\n");
      helperFile.writeAsStringSync('int helper() => 42;\n');

      final graph = DependencyGraphStore(workspaceRoot: tempDir.path);
      await graph.updateForPaths([apiFile.path, helperFile.path]);

      final impact = graph.planImpact([helperFile.path]);
      expect(
        impact.invalidatedPaths,
        containsAll([
          File(apiFile.path).absolute.path.replaceAll('\\', '/'),
          File(helperFile.path).absolute.path.replaceAll('\\', '/'),
        ]),
      );
    });

    test('resolves package self-imports and detects container touchpoints',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'dep_graph_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final libDir = Directory('${tempDir.path}/lib/src')
        ..createSync(recursive: true);
      final registryFile = File('${libDir.path}/registry.dart');
      final featureFile = File('${libDir.path}/feature.dart');

      registryFile.writeAsStringSync('''
void configure(container) {
  container.register<Foo>(() => Foo());
}
''');
      featureFile.writeAsStringSync(
        "import 'package:sample_app/src/registry.dart';\nvoid run() {}\n",
      );

      final graph = DependencyGraphStore(
        workspaceRoot: tempDir.path,
        packageName: 'sample_app',
      );
      await graph.updateForPaths([registryFile.path, featureFile.path]);

      final impact = graph.planImpact([registryFile.path]);
      expect(impact.containerShapeTouched, isTrue);
      expect(
        impact.invalidatedPaths,
        contains(File(featureFile.path).absolute.path.replaceAll('\\', '/')),
      );
    });

    test('detects route touchpoints through dependent expansion', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'dep_graph_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final libDir = Directory('${tempDir.path}/lib/src')
        ..createSync(recursive: true);
      final routeFile = File('${libDir.path}/routes.dart');
      final modelFile = File('${libDir.path}/model.dart');

      routeFile.writeAsStringSync('''
import 'model.dart';
void register(app) {
  app.get('/users', (req, res) => res.send('ok'));
}
''');
      modelFile.writeAsStringSync('class UserModel {}\n');

      final graph = DependencyGraphStore(workspaceRoot: tempDir.path);
      await graph.updateForPaths([routeFile.path, modelFile.path]);

      final impact = graph.planImpact([modelFile.path]);
      expect(impact.routeGraphTouched, isTrue);
      expect(
        impact.invalidatedPaths,
        contains(File(routeFile.path).absolute.path.replaceAll('\\', '/')),
      );
    });
  });
}
