import 'package:fletch/fletch.dart';
import '../lib/src/auth_module.dart';

Future<void> main() async {
  // 1. Initialize Fletch with Session Configuration
  // In production, use a secure secret from environment variables
  final app = Fletch(
    sessionSecret:
        'super_secret_key_change_this_In_Prod_please_longer_than_32_chars',
    sessionStore: MemorySessionStore(),
  );

  // 2. Global Middleware
  app.use(loggerMiddleware);

  // 3. Create and Mount Auth Module
  // We mount it at '/auth', so routes will be '/auth/login', '/auth/register', etc.
  final authModule = createAuthModule();

  print('🔌 Mounting Auth Module at /auth...');
  app.mount('/auth', authModule);

  // 4. Main App Routes
  app.get('/', (req, res) {
    res.html('''
      <h1>🏠 Main App</h1>
      <p>This is the main application.</p>
      <ul>
        <li><a href="/auth/me">Check Profile (GET /auth/me)</a></li>
        <li>POST /auth/login to sign in</li>
        <li>POST /auth/register to sign up</li>
      </ul>
    ''');
  });

  // 5. Start Server
  final port = 8080;
  await app.listen(port);
  print('🚀 Server running at http://localhost:$port');
}

/// Simple logger middleware
Future<dynamic> loggerMiddleware(
    Request req, Response res, NextFunction next) async {
  final start = DateTime.now();
  final result = await next();
  final duration = DateTime.now().difference(start).inMilliseconds;
  print('${req.method} ${req.uri.path} - ${res.statusCode} (${duration}ms)');
  return result;
}
