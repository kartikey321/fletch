import 'generation_id.dart';
import 'reload_phase.dart';
import 'reload_strategy.dart';

/// Immutable transaction record for one reload attempt.
class ReloadTransaction {
  final String transactionId;
  final GenerationId generationFrom;
  final GenerationId generationTo;
  final ReloadStrategy strategy;
  final ReloadPhase phase;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? message;

  const ReloadTransaction({
    required this.transactionId,
    required this.generationFrom,
    required this.generationTo,
    required this.strategy,
    required this.phase,
    required this.createdAt,
    required this.updatedAt,
    this.message,
  });

  factory ReloadTransaction.detected({
    required String transactionId,
    required GenerationId generationFrom,
    required GenerationId generationTo,
    required ReloadStrategy strategy,
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now().toUtc();
    return ReloadTransaction(
      transactionId: transactionId,
      generationFrom: generationFrom,
      generationTo: generationTo,
      strategy: strategy,
      phase: ReloadPhase.detected,
      createdAt: ts,
      updatedAt: ts,
    );
  }

  bool canTransitionTo(ReloadPhase next) {
    if (phase == next) return true;
    switch (phase) {
      case ReloadPhase.detected:
        return next == ReloadPhase.classifying || next == ReloadPhase.aborted;
      case ReloadPhase.classifying:
        return next == ReloadPhase.compiling ||
            next == ReloadPhase.failed ||
            next == ReloadPhase.aborted;
      case ReloadPhase.compiling:
        return next == ReloadPhase.staging ||
            next == ReloadPhase.failed ||
            next == ReloadPhase.aborted;
      case ReloadPhase.staging:
        return next == ReloadPhase.activating ||
            next == ReloadPhase.failed ||
            next == ReloadPhase.aborted;
      case ReloadPhase.activating:
        return next == ReloadPhase.retiring ||
            next == ReloadPhase.failed ||
            next == ReloadPhase.aborted;
      case ReloadPhase.retiring:
        return next == ReloadPhase.committed ||
            next == ReloadPhase.failed ||
            next == ReloadPhase.aborted;
      case ReloadPhase.committed:
      case ReloadPhase.failed:
      case ReloadPhase.aborted:
        return false;
    }
  }

  ReloadTransaction transitionTo(
    ReloadPhase next, {
    String? message,
    DateTime? now,
  }) {
    if (!canTransitionTo(next)) {
      throw StateError(
        'Invalid reload transition: ${phase.name} -> ${next.name} '
        '(tx=$transactionId)',
      );
    }
    return ReloadTransaction(
      transactionId: transactionId,
      generationFrom: generationFrom,
      generationTo: generationTo,
      strategy: strategy,
      phase: next,
      createdAt: createdAt,
      updatedAt: now ?? DateTime.now().toUtc(),
      message: message ?? this.message,
    );
  }

  Map<String, Object?> toJson() => {
        'transactionId': transactionId,
        'generationFrom': generationFrom.toJson(),
        'generationTo': generationTo.toJson(),
        'strategy': strategy.name,
        'phase': phase.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'message': message,
      };

  factory ReloadTransaction.fromJson(Map<String, Object?> json) {
    String readString(String key) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
      throw FormatException('Invalid or missing "$key": $json');
    }

    DateTime readDate(String key) {
      final value = readString(key);
      return DateTime.parse(value).toUtc();
    }

    Map<String, Object?> readMap(String key) {
      final value = json[key];
      if (value is Map<String, Object?>) return value;
      if (value is Map) {
        return value.cast<String, Object?>();
      }
      throw FormatException('Invalid or missing "$key": $json');
    }

    return ReloadTransaction(
      transactionId: readString('transactionId'),
      generationFrom: GenerationId.fromJson(readMap('generationFrom')),
      generationTo: GenerationId.fromJson(readMap('generationTo')),
      strategy: ReloadStrategyX.fromName(readString('strategy')),
      phase: ReloadPhaseX.fromName(readString('phase')),
      createdAt: readDate('createdAt'),
      updatedAt: readDate('updatedAt'),
      message: json['message'] as String?,
    );
  }
}
