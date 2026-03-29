import '../transaction/generation_id.dart';
import '../transaction/reload_phase.dart';
import '../transaction/reload_strategy.dart';

enum ReloadEventType {
  lifecycle,
  phaseChanged,
  failed,
  committed,
  aborted,
}

/// Structured event emitted by reload engine.
class ReloadEvent {
  final ReloadEventType type;
  final String transactionId;
  final GenerationId generationFrom;
  final GenerationId generationTo;
  final ReloadStrategy strategy;
  final ReloadPhase phase;
  final DateTime timestamp;
  final String? message;

  const ReloadEvent({
    required this.type,
    required this.transactionId,
    required this.generationFrom,
    required this.generationTo,
    required this.strategy,
    required this.phase,
    required this.timestamp,
    this.message,
  });

  Map<String, Object?> toJson() => {
        'type': type.name,
        'transactionId': transactionId,
        'generationFrom': generationFrom.toJson(),
        'generationTo': generationTo.toJson(),
        'strategy': strategy.name,
        'phase': phase.name,
        'timestamp': timestamp.toIso8601String(),
        'message': message,
      };

  factory ReloadEvent.fromJson(Map<String, Object?> json) {
    String readString(String key) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
      throw FormatException('Invalid or missing "$key": $json');
    }

    Map<String, Object?> readMap(String key) {
      final value = json[key];
      if (value is Map<String, Object?>) return value;
      if (value is Map) {
        return value.cast<String, Object?>();
      }
      throw FormatException('Invalid or missing "$key": $json');
    }

    ReloadEventType readType(String name) {
      for (final v in ReloadEventType.values) {
        if (v.name == name) return v;
      }
      throw FormatException('Unknown ReloadEventType: $name');
    }

    return ReloadEvent(
      type: readType(readString('type')),
      transactionId: readString('transactionId'),
      generationFrom: GenerationId.fromJson(readMap('generationFrom')),
      generationTo: GenerationId.fromJson(readMap('generationTo')),
      strategy: ReloadStrategyX.fromName(readString('strategy')),
      phase: ReloadPhaseX.fromName(readString('phase')),
      timestamp: DateTime.parse(readString('timestamp')).toUtc(),
      message: json['message'] as String?,
    );
  }
}
