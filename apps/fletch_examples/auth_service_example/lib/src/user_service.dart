import 'package:crypto/crypto.dart';
import 'dart:convert';

/// Simple User model
class User {
  final String id;
  final String email;
  final String passwordHash;

  User(this.id, this.email, this.passwordHash);

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
      };
}

/// Mock service to handle user data
class UserService {
  // In-memory storage simulating a database
  final Map<String, User> _users = {};

  /// Find a user by email
  Future<User?> findUserByEmail(String email) async {
    // Simulate DB delay
    await Future.delayed(Duration(milliseconds: 10));
    try {
      return _users.values.firstWhere((u) => u.email == email);
    } catch (_) {
      return null;
    }
  }

  /// Create a new user
  Future<User> createUser(String email, String password) async {
    // Check if user already exists
    if (await findUserByEmail(email) != null) {
      throw Exception('User already exists');
    }

    // Hash password (simple SHA256 for demo)
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    final passwordHash = digest.toString();

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final user = User(id, email, passwordHash);

    _users[id] = user;
    return user;
  }

  /// Verify password
  bool verifyPassword(User user, String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return user.passwordHash == digest.toString();
  }
}
