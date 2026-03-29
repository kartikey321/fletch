import 'package:watcher/watcher.dart';

/// Coalescing queue for watcher events used by the control-plane loop.
///
/// Events are deduplicated by path (last write wins), then drained as a stable
/// sorted batch so reload processing remains deterministic.
class ChangeBatchQueue {
  final Map<String, WatchEvent> _pendingByPath = {};

  bool get isEmpty => _pendingByPath.isEmpty;

  int get depth => _pendingByPath.length;

  void enqueueAll(Iterable<WatchEvent> events) {
    for (final event in events) {
      final key = event.path.replaceAll('\\', '/');
      _pendingByPath[key] = event;
    }
  }

  List<WatchEvent> drain() {
    if (_pendingByPath.isEmpty) return const [];
    final entries = _pendingByPath.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    _pendingByPath.clear();
    return entries.map((entry) => entry.value).toList(growable: false);
  }
}
