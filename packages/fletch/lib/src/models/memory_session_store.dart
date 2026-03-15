import 'dart:async';
import 'package:fletch/src/models/session_store.dart';

/// In-memory session store implementation.
///
/// **WARNING**: This store is NOT suitable for production deployments with
/// multiple server instances. Sessions are:
/// - Lost on server restart
/// - Not shared across instances
/// - Limited by available RAM
///
/// **Use Cases**:
/// - Development and testing
/// - Single-instance deployments
/// - Prototyping
///
/// **Production Alternative**:
/// Use a distributed store like Redis, PostgreSQL, or MongoDB for
/// production multi-instance deployments.
///
/// ## Features
/// - Automatic session expiration with configurable TTL
/// - Periodic cleanup of expired sessions
/// - Thread-safe operations
/// - Memory-efficient with automatic pruning
///
/// ## Example
/// ```dart
/// final store = MemorySessionStore(
///   defaultTTL: Duration(hours: 24),
///   cleanupInterval: Duration(minutes: 15),
/// );
///
/// final app = Fletch(sessionStore: store);
/// ```
class MemorySessionStore implements SessionStore {
  final Map<String, _SessionEntry> _sessions = {};
  final Duration defaultTTL;
  final Duration _cleanupInterval;
  final int maxSessions;
  Timer? _cleanupTimer;

  /// Creates a memory-backed session store.
  ///
  /// Parameters:
  /// - [defaultTTL]: Default session lifetime (default: 24 hours)
  /// - [cleanupInterval]: How often to clean expired sessions (default: 10 minutes)
  /// - [maxSessions]: Maximum live sessions kept in memory (default: 10,000).
  ///   When the limit is reached, the oldest sessions are evicted to prevent
  ///   unbounded memory growth under sustained traffic.
  MemorySessionStore({
    this.defaultTTL = const Duration(hours: 24),
    Duration cleanupInterval = const Duration(minutes: 10),
    this.maxSessions = 10000,
  }) : _cleanupInterval = cleanupInterval {
    _startCleanup();
  }

  @override
  Future<Map<String, dynamic>?> load(String sessionId) async {
    final entry = _sessions[sessionId];

    // Check if session exists and is not expired
    if (entry == null || entry.isExpired) {
      if (entry != null) {
        _sessions.remove(sessionId); // Clean up expired session
      }
      return null;
    }

    // Return a copy of the data to prevent external modifications
    return Map<String, dynamic>.from(entry.data);
  }

  @override
  Future<void> save(
    String sessionId,
    Map<String, dynamic> data, {
    Duration? ttl,
  }) async {
    final expiresAt = DateTime.now().add(ttl ?? defaultTTL);

    // Evict oldest entries when at capacity (before inserting a new one).
    if (!_sessions.containsKey(sessionId) &&
        _sessions.length >= maxSessions) {
      // Dart Maps are insertion-ordered: the first key is the oldest.
      _sessions.remove(_sessions.keys.first);
    }

    _sessions[sessionId] = _SessionEntry(
      data: Map<String, dynamic>.from(data), // Store a copy
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> destroy(String sessionId) async {
    _sessions.remove(sessionId);
  }

  @override
  Future<void> touch(String sessionId, {Duration? ttl}) async {
    final entry = _sessions[sessionId];
    if (entry != null && !entry.isExpired) {
      entry.expiresAt = DateTime.now().add(ttl ?? defaultTTL);
    }
  }

  @override
  Future<void> cleanup() async {
    _sessions.removeWhere((_, entry) => entry.isExpired);
  }

  @override
  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    _sessions.clear();
  }

  void _startCleanup() {
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) {
      cleanup();
    });
  }

  /// Returns the number of active sessions (for monitoring/debugging).
  int get sessionCount => _sessions.length;

  /// Returns the number of expired sessions awaiting cleanup.
  int get expiredSessionCount {
    return _sessions.values.where((entry) => entry.isExpired).length;
  }
}

/// Internal session entry with expiration tracking.
class _SessionEntry {
  final Map<String, dynamic> data;
  DateTime expiresAt;

  _SessionEntry({
    required this.data,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
