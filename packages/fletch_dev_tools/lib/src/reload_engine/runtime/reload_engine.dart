import '../classifier/change_set.dart';
import '../transaction/reload_strategy.dart';
import '../transaction/reload_transaction.dart';
import 'reload_event.dart';

abstract class ReloadEngine {
  bool get isRunning;
  Stream<ReloadEvent> get events;

  Future<ReloadTransaction> submit(
    ChangeSet changeSet, {
    required ReloadStrategy strategy,
    String? message,
    DateTime? now,
  });

  Future<void> start();
  Future<void> stop();
}
