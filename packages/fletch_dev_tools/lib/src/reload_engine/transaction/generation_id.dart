/// Immutable generation identifier for runtime snapshots.
class GenerationId {
  final String value;

  const GenerationId(this.value);

  Map<String, Object?> toJson() => {'value': value};

  factory GenerationId.fromJson(Map<String, Object?> json) {
    final value = json['value'];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid generation id payload: $json');
    }
    return GenerationId(value);
  }

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GenerationId && value == other.value;

  @override
  int get hashCode => value.hashCode;
}
