# Sessions

Fletch provides built-in session management with pluggable storage backends.

## Quick Start

Enable sessions with a secret key:

```dart
final app = Fletch(
  sessionSecret: 'your-secret-key-min-32-characters-long!',
);

app.get('/counter', (req, res) {
  final count = (req.session['count'] as int? ?? 0) + 1;
  req.session['count'] = count;
  res.json({'visits': count});
});

await app.listen(3000);
```

## How Sessions Work

1. **First Request**: Client has no session cookie
2. **Server Creates Session**: Generates session ID and stores data
3. **Send Cookie**: Server sends signed session cookie to client
4. **Subsequent Requests**: Client sends cookie, server loads session

## Accessing Sessions

### Reading Data

```dart
app.get('/profile', (req, res) {
  final userId = req.session['userId'];
  final username = req.session['username'];
  
  if (userId == null) {
    return res.status(401).json({'error': 'Not logged in'});
  }
  
  res.json({
    'userId': userId,
    'username': username,
  });
});
```

### Writing Data

```dart
app.post('/login', (req, res) async {
  final body = await req.body;
  
  // Verify credentials...
  
  // Store in session
  req.session['userId'] = '123';
  req.session['username'] = body['username'];
  req.session['loginTime'] = DateTime.now().toIso8601String();
  
  res.json({'success': true});
});
```

### Deleting Data

```dart
app.post('/logout', (req, res) {
  req.session.clear();
  res.json({'message': 'Logged out'});
});
```

## Session Stores

### Memory Store (Default)

Good for development, not for production:

```dart
final app = Fletch(
  sessionSecret: 'secret',
  sessionStore: MemorySessionStore(
    maxSessions: 10000, // evicts oldest when limit reached (default)
  ),
);
```

**Limitations:**
- Data lost on server restart
- Doesn't work with multiple server instances
- Bounded to `maxSessions` entries (oldest evicted when full)

### Custom Store

Implement `SessionStore` for your backend:

```dart
class RedisSessionStore implements SessionStore {
  final RedisClient redis;
  
  RedisSessionStore(this.redis);
  
  @override
  Future<Map<String, dynamic>?> get(String sessionId) async {
    final data = await redis.get('session:$sessionId');
    return data != null ? jsonDecode(data) : null;
  }
  
  @override
  Future<void> set(String sessionId, Map<String, dynamic> data, {Duration? ttl}) async {
    await redis.set(
      'session:$sessionId',
      jsonEncode(data),
      ex: ttl?.inSeconds ?? 86400, // 24 hours default
    );
  }
  
  @override
  Future<void> destroy(String sessionId) async {
    await redis.del('session:$sessionId');
  }
  
  @override
  Future<void> dispose() async {
    await redis.close();
  }
}

// Usage
final app = Fletch(
  sessionSecret: 'secret',
  sessionStore: RedisSessionStore(redisClient),
);
```

## Session Configuration

### Session Secret

**Required** - Used to sign session cookies:

```dart
final app = Fletch(
  sessionSecret: Platform.environment['SESSION_SECRET']!,
);
```

Requirements:
- Minimum 32 characters
- Cryptographically random
- Never commit to git
- Rotate periodically

### Secure Cookies

Enable for HTTPS (production):

```dart
final app = Fletch(
  sessionSecret: 'secret',
  secureCookies: true, // HTTPS only
);
```

### Cookie Name

Customize the session cookie name:

```dart
final app = Fletch(
  sessionSecret: 'secret',
  sessionCookieName: 'my_app_session',
);
```

## Authentication Example

Complete login/logout flow:

```dart
void main() async {
  final app = Fletch(
    sessionSecret: Platform.environment['SESSION_SECRET']!,
    secureCookies: true,
  );
  
  // Login endpoint
  app.post('/login', (req, res) async {
    final body = await req.body;
    final email = body['email'];
    final password = body['password'];

    // Validate credentials (example)
    if (email == 'user@example.com' && password == 'password') {
      // Regenerate session ID to prevent session fixation
      await req.session.regenerate();

      req.session['userId'] = '123';
      req.session['email'] = email;
      req.session['loginAt'] = DateTime.now().toIso8601String();

      return res.json({'success': true});
    }

    res.status(401).json({'error': 'Invalid credentials'});
  });
  
  // Protected route
  app.get('/dashboard', requireAuth, (req, res) {
    res.json({
      'user': req.session['email'],
      'loggedIn': true,
    });
  });
  
  // Logout
  app.post('/logout', (req, res) {
    req.session.clear();
    res.json({'message': 'Logged out successfully'});
  });
  
  await app.listen(3000);
}

// Auth middleware
Future<void> requireAuth(Request req, Response res, NextFunction next) async {
  if (!req.session.containsKey('userId')) {
    return res.status(401).json({'error': 'Authentication required'});
  }
  await next();
}
```

## Session Lifetime

Sessions expire after inactivity:

```dart
final app = Fletch(
  sessionSecret: 'secret',
  sessionStore: MemorySessionStore(
    cleanupInterval: Duration(minutes: 5),  // Cleanup frequency
  ),
);
```

Default TTL: 24 hours

## Security Best Practices

### 1. Use Strong Secrets

```dart
// ❌ Bad
sessionSecret: '12345'

// ✅ Good
sessionSecret: Platform.environment['SESSION_SECRET']!
```

Generate with:
```bash
dart run -e "import 'dart:math'; import 'dart:convert'; print(base64Encode(List.generate(32, (_) => Random.secure().nextInt(256))))"
```

### 2. HTTPS Only in Production

```dart
final app = Fletch(
  sessionSecret: secret,
  secureCookies: Platform.environment['ENV'] == 'production',
);
```

### 3. Regenerate Session on Login

Always call `session.regenerate()` after a successful login. This destroys the old session ID and issues a fresh one, preventing [session fixation attacks](https://owasp.org/www-community/attacks/Session_fixation) where an attacker pre-sets a known session ID before the victim authenticates.

```dart
app.post('/login', (req, res) async {
  final body = await req.body;
  final ok = await validateCredentials(body['email'], body['password']);

  if (ok) {
    // Invalidate the pre-auth session ID and generate a new one
    await req.session.regenerate();

    req.session['userId'] = userId;
    req.session['loginAt'] = DateTime.now().toIso8601String();
    return res.json({'success': true});
  }

  res.status(401).json({'error': 'Invalid credentials'});
});
```

`regenerate()` is a no-op if called more than once in the same request.

### 4. Implement Session Timeout

```dart
Future<void> checkSessionTimeout(Request req, Response res, NextFunction next) async {
  final loginTime = req.session['loginAt'] as String?;
  
  if (loginTime != null) {
    final login = DateTime.parse(loginTime);
    final now = DateTime.now();
    
    if (now.difference(login).inHours > 8) {
      req.session.clear();
      return res.status(401).json({'error': 'Session expired'});
    }
  }
  
  await next();
}
```

### 5. Store Minimal Data

```dart
// ❌ Don't store sensitive data
req.session['password'] = password;
req.session['creditCard'] = ccNumber;

// ✅ Store only IDs and references
req.session['userId'] = userId;
```

## Testing Sessions

```dart
import 'package:test/test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('login creates session', () async {
    final response = await http.post(
      Uri.parse('http://localhost:3000/login'),
      body: {'email': 'test@example.com', 'password': 'pass'},
    );
    
    expect(response.statusCode, 200);
    
    // Extract session cookie
    final cookie = response.headers['set-cookie'];
    expect(cookie, isNotNull);
    
    // Use session in next request
    final dashboard = await http.get(
      Uri.parse('http://localhost:3000/dashboard'),
      headers: {'cookie': cookie!},
    );
    
    expect(dashboard.statusCode, 200);
  });
}
```

## Common Patterns

### Role-Based Access

```dart
req.session['role'] = 'admin';

Future<void> requireAdmin(Request req, Response res, NextFunction next) async {
  if (req.session['role'] != 'admin') {
    return res.status(403).json({'error': 'Admin only'});
  }
  await next();
}
```

### Shopping Cart

```dart
app.post('/cart/add', (req, res) async {
  final body = await req.body;
  final cart = req.session['cart'] as List? ?? [];
  
  cart.add(body['itemId']);
  req.session['cart'] = cart;
  
  res.json({'cartSize': cart.length});
});
```

### Remember Me

```dart
app.post('/login', (req, res) async {
  final body = await req.body;
  final rememberMe = body['rememberMe'] == true;
  
  req.session['userId'] = userId;
  
  if (rememberMe) {
    res.cookie('remember_token', token, maxAge: Duration(days: 30));
  }
});
```

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/core-concepts/middleware" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🧩 Middleware</span>
  </a>
  <a href="/core-concepts/error-handling" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🚧 Error Handling</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
