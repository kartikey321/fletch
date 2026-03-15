import 'dart:async';
import 'dart:io';

import 'package:fletch/fletch.dart';

Future<void> main() async {
  final app = Fletch();

  // Register shared dependencies.
  app.inject<Clock>(SystemClock());

  // Global middleware.
  app.use(app.cors(allowedOrigins: ['http://localhost:3000']));
  app.use(
      app.rateLimiter(maxRequests: 200, window: const Duration(minutes: 1)));
  app.setErrorHandler((err, req, res) {
    print(err);
    res.json({'error': err.toString()}, statusCode: 500);
  });
  // Simple health endpoint.
  app.get('/health', (req, res) {
    res.json({'status': 'ok', 'timestamp': req.container.get<Clock>().now()});
  });

  // Echo JSON payloads back to the client.
  app.post('/echo', (req, res) async {
    final payload = await req.body;
    res.json({'received': payload});
  });

  // Mount a controller for user routes.
  app.useController('/users', UsersController());

  // Mount an isolated admin module.
  final admin = IsolatedContainer(prefix: '/admin');
  admin.use((req, res, next) {
    res.setHeader('X-Isolated', 'admin');
    return next();
  });
  admin.get('/', (req, res) => res.text('Welcome to the admin module'));
  admin.get('/stats', (req, res) async {
    res.status(200).json({'uptimeSeconds': ProcessInfo.currentRss});
  });
  admin.mount(app);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await app.listen(port);
  print('Fletch example running on http://localhost:$port');
}

class UsersController extends Controller {
  static final List<Map<String, dynamic>> _users = [
    {'id': 1, 'name': 'Ada'},
    {'id': 2, 'name': 'Linus'},
  ];

  @override
  void registerRoutes(ControllerOptions options) {
    options.get('/', _listUsers);
    options.get('/:id(\\d+)', _getUserById);
  }

  Future<void> _listUsers(Request request, Response response) async {
    response.json({'data': _users});
  }

  Future<void> _getUserById(Request request, Response response) async {
    final id = int.tryParse(request.params['id'] ?? '');
    final user =
        _users.firstWhere((entry) => entry['id'] == id, orElse: () => {});

    if (user.isEmpty) {
      throw NotFoundError('User $id not found');
    }

    response.json({'data': user});
  }
}

abstract class Clock {
  String now();
}

class SystemClock implements Clock {
  @override
  String now() => DateTime.now().toUtc().toIso8601String();
}
