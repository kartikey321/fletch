import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

/// 🧪 Proof of Concept: State Preservation during Hot Reload
///
/// This script demonstrates that Dart's `reloadSources` can update logic
/// while PRESERVING state (static/global variables).
///
/// Flow:
/// 1. Start a target Dart process (the "App").
/// 2. App has a global counter. We increment it to prove state exists.
/// 3. We modify the App's source code (logic change).
/// 4. We trigger `reloadSources` via VM Service.
/// 5. We verify the counter IS NOT RESET (State Preserved).
/// 6. We verify the output logic IS CHANGED (Code Updated).

const targetFileName = 'target_app.dart';

void main() async {
  print('🧪 Starting POC: State Preservation...');

  // 1. Create the initial Target App
  await _createTargetApp(version: 1);
  print('📝 Created target app (v1)');

  // 2. Start the Target App with VM Service enabled
  // We use --enable-vm-service=0 to let OS pick a free port
  final process = await Process.start(
    'dart',
    ['--enable-vm-service=0', '--disable-service-auth-codes', targetFileName],
  );

  // Pipe output to see what's happening
  final outputController = StreamController<String>();
  process.stdout
      .transform(utf8.decoder)
      .transform(LineSplitter())
      .listen((line) {
    if (line.isNotEmpty) {
      print('[APP] $line');
      outputController.add(line);
    }
  });

  process.stderr
      .transform(utf8.decoder)
      .transform(LineSplitter())
      .listen((line) {
    if (line.isNotEmpty) {
      print('[APP ERROR] $line');
    }
  });

  // 3. Wait for VM Service URI
  print('⏳ Waiting for VM Service...');
  final vmServiceUri = await outputController.stream
      .firstWhere(
          (line) => line.startsWith('The Dart VM service is listening on'))
      .then((line) {
    final uriStr = line.split('on ').last.trim();
    return Uri.parse(uriStr);
  });

  // Convert http header URI to ws URI
  // Remove leading slash from path segments if present to avoid double slashes
  final pathSegments = [...vmServiceUri.pathSegments, 'ws'];
  if (pathSegments.first.isEmpty) pathSegments.removeAt(0);

  final wsUri = vmServiceUri.replace(scheme: 'ws', pathSegments: pathSegments);

  print('🔌 Connecting to VM Service: $wsUri');
  final service = await vmServiceConnectUri(wsUri.toString());
  final vm = await service.getVM();
  final isolateId = vm.isolates!.first.id!;

  // 4. Simulate Usage (Increment State)
  // The app increments automatically every second.
  // We'll wait for a few increments.
  print('⏳ Running application to build state...');
  await Future.delayed(Duration(seconds: 3));

  // 5. Inject Code Change (v2)
  print('✏️  Modifying source code (Method Body Change)...');
  await _createTargetApp(version: 2);

  // 6. Trigger Hot Reload
  print('🔥 Triggering Hot Reload...');
  final stopwatch = Stopwatch()..start();

  final report = await service.reloadSources(isolateId);

  stopwatch.stop();
  if (report.success ?? false) {
    print('✅ Reload successful in ${stopwatch.elapsedMilliseconds}ms');
  } else {
    print('❌ Reload failed!');
    exit(1);
  }

  // 7. Observe Results
  print('👀 Observing post-reload behavior...');
  await Future.delayed(Duration(seconds: 3));

  // 8. Cleanup
  print('🧹 Cleaning up...');
  process.kill();
  await service.dispose();
  await File(targetFileName).delete();

  print('\n✨ POC Complete. Analyze the [APP] logs above.');
  print(
      'If SUCCESS: You should see message change from "Version 1" to "Version 2"');
  print(
      '            BUT the count should continue incrementing (e.g. 3, 4, 5...)');
  print('            It should NOT reset to 1.');
}

Future<void> _createTargetApp({required int version}) async {
  final message = version == 1 ? "Version 1 (Old)" : "Version 2 (New Logic!)";

  final code = '''
import 'dart:async';

// GLOBAL STATE - Should be preserved!
int globalCounter = 0;

void main() {
  print('The Dart VM service is listening on ' + (Uri.base.toString())); // Placeholder, usually prints automatically
  
  Timer.periodic(Duration(seconds: 1), (timer) {
    globalCounter++;
    print(generateMessage());
  });
}

// Method we will change
String generateMessage() {
  return "[$message] Count: \$globalCounter";
}
''';

  await File(targetFileName).writeAsString(code);
}
