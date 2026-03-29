/// Coalesced set of changed files associated with one detection window.
class ChangeSet {
  final List<String> changedPaths;
  final DateTime detectedAt;

  ChangeSet({
    required List<String> changedPaths,
    DateTime? detectedAt,
  })  : changedPaths = List.unmodifiable(changedPaths),
        detectedAt = (detectedAt ?? DateTime.now()).toUtc();

  bool get isEmpty => changedPaths.isEmpty;

  Map<String, Object?> toJson() => {
        'changedPaths': changedPaths,
        'detectedAt': detectedAt.toIso8601String(),
      };
}
