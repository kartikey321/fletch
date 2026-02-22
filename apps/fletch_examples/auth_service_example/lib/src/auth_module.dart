import 'package:fletch/fletch.dart';
import 'user_service.dart';

/// Factory function to create the Auth Module
IsolatedContainer createAuthModule({UserService? mockService}) {
  // Create an isolated container
  // Note: We don't necessarily need to set a prefix here if we mount it with one,
  // but it's good practice if it's meant to be standalone.
  // We'll let the user decide the prefix when mounting.
  final container = IsolatedContainer();

  // 1. Register Dependencies (Scoped to this container)
  final userService = mockService ?? UserService();
  container.registerSingleton<UserService>(userService);

  // 3. Define Routes

  // POST /register
  container.post('/register', (req, res) async {
    final body = await req.body as Map<String, dynamic>?;
    if (body == null || body['email'] == null || body['password'] == null) {
      return res
          .json({'error': 'Email and password required'}, statusCode: 400);
    }

    try {
      final user =
          await userService.createUser(body['email'], body['password']);
      return res.json({
        'message': 'User registered',
        'user': user.toJson(),
      }, statusCode: 201);
    } catch (e) {
      return res.json({'error': e.toString()}, statusCode: 409);
    }
  });

  // POST /login
  container.post('/login', (req, res) async {
    final body = await req.body as Map<String, dynamic>?;
    if (body == null || body['email'] == null || body['password'] == null) {
      return res
          .json({'error': 'Email and password required'}, statusCode: 400);
    }

    final user = await userService.findUserByEmail(body['email']);
    if (user == null || !userService.verifyPassword(user, body['password'])) {
      return res.json({'error': 'Invalid credentials'}, statusCode: 401);
    }

    // Set session data (using the parent app's session store)
    final session = await req.session;
    session['userId'] = user.id;
    session['email'] = user.email;

    return res.json({'message': 'Logged in', 'user': user.toJson()});
  });

  // POST /logout
  container.post('/logout', (req, res) async {
    final session = await req.session;
    await session.destroy();
    return res.json({'message': 'Logged out'});
  });

  // GET /me
  container.get('/me', (req, res) async {
    final session = await req.session;
    final userId = session['userId'];

    if (userId == null) {
      return res.json({'error': 'Unauthorized'}, statusCode: 401);
    }

    // In a real app, you might fetch fresh data from DB
    return res.json({
      'id': userId,
      'email': session['email'],
    });
  });

  return container;
}
