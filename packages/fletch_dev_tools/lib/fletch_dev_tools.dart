/// Development tools for Fletch framework.
///
/// Provides hot reload, hot restart, and CLI tools for a Flutter-like
/// development experience with backend Dart applications.
///
/// ## Usage
///
/// ### Command Line
///
/// ```bash
/// # Activate globally
/// dart pub global activate fletch_dev_tools
///
/// # Run dev server
/// fletch dev --entry bin/main.dart
/// ```
///
/// ### As a Library
///
/// ```dart
/// import 'package:fletch_dev_tools/fletch_dev_tools.dart';
///
/// Future<void> main() async {
///   final devServer = FletchDevServer(
///     entryPoint: 'bin/main.dart',
///     port: 3000,
///     watchDirectories: ['lib', 'routes'],
///   );
///
///   await devServer.start();
/// }
/// ```
library fletch_dev_tools;

export 'src/ast_change_analyzer.dart';
export 'src/change_batch_processor.dart';
export 'src/change_batch_queue.dart';
export 'src/change_analyzer.dart';
export 'src/dev_file_watcher.dart';
export 'src/dev_server.dart';
export 'src/hot_reloader.dart';
export 'src/process_manager.dart';
export 'src/reload_engine/reload_engine.dart';
export 'src/reload_engine/compiler/incremental_compiler_session.dart';
export 'src/runtime/fletch_dev_hot_reload.dart';
