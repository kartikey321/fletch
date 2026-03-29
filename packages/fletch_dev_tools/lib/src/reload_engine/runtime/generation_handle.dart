import '../transaction/generation_id.dart';

/// Immutable runtime snapshot descriptor.
class GenerationHandle {
  final GenerationId id;
  final DateTime createdAt;
  final DateTime? activatedAt;
  final Object? routeGraphSnapshot;
  final Object? middlewareSnapshot;
  final Object? containerSnapshot;
  final Map<String, Object?> metadata;

  const GenerationHandle({
    required this.id,
    required this.createdAt,
    this.activatedAt,
    this.routeGraphSnapshot,
    this.middlewareSnapshot,
    this.containerSnapshot,
    this.metadata = const {},
  });

  GenerationHandle markActivated({DateTime? at}) {
    return GenerationHandle(
      id: id,
      createdAt: createdAt,
      activatedAt: (at ?? DateTime.now()).toUtc(),
      routeGraphSnapshot: routeGraphSnapshot,
      middlewareSnapshot: middlewareSnapshot,
      containerSnapshot: containerSnapshot,
      metadata: metadata,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'activatedAt': activatedAt?.toIso8601String(),
        'metadata': metadata,
      };
}
