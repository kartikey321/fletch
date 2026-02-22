<h1>
  <img src="https://docs.fletch.mahawarkartikey.in/images/logo.svg" alt="Fletch Logo" height="100" style="vertical-align: bottom; margin-right: 10px;"/>
  Fletch
</h1>

<br clear="left"/>

[![pub package](https://img.shields.io/pub/v/fletch.svg)](https://pub.dev/packages/fletch)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Discord](https://img.shields.io/discord/1455638457639768285?color=5865F2&label=discord&logo=discord&logoColor=white)](https://discord.gg/rykqYF6Jvn)

<!-- ROB_NOTICE_START -->
<!-- ROB_NOTICE_END -->

> **📦 Package History Notice**  
> This package was previously a jQuery-like library by [Rob Kellett](https://github.com/RobKellett). As of version 2.0.0 (January 2025), it has been repurposed as an Express-inspired HTTP framework. If you're looking for the original jQuery-like library, please see [version 0.3.0](https://pub.dev/packages/fletch/versions/0.3.0) or the [original repository](https://github.com/RobKellett/Fletch). Thank you to Rob for graciously transferring the package name!


An Express-inspired HTTP framework for Dart. It brings familiar routing,
middleware, and dependency-injection patterns to `dart:io` while remaining
lightweight and dependency-free beyond `GetIt`.

📚 **[Documentation](https://docs.fletch.mahawarkartikey.in/)** | 
🐛 **[Issues](https://github.com/kartikey321/fletch/issues)** | 
💬 **[Discussions](https://github.com/kartikey321/fletch/discussions)** |
🎮 **[Discord](https://discord.gg/rykqYF6Jvn)**

## Why Fletch?

If you're coming from **Express.js** or **Node.js**, Fletch will feel instantly familiar:

- ✅ **Express-like API** - `app.get()`, `app.post()`, middleware, it's all here
- ⚡ **Fast** - Radix-tree routing, minimal overhead
- 🔒 **Secure by default** - HMAC-signed sessions, CORS, rate limiting built-in
- 📡 **Real-time** - Built-in SSE and streaming support
- 🎯 **Production-ready** - Graceful shutdown, request timeouts, error handling
- 🧩 **Modular** - Controllers, isolated containers, dependency injection
- 📦 **Lightweight** - Minimal dependencies, pure Dart

## Features

- Fast radix-tree router with support for path parameters and nested routers
- Middleware pipeline with global and per-route handlers
- Server-Sent Events (SSE) for real-time server-to-client streaming
- Generic streaming support for files and chunked data
- Full HTTP method support (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS)
- `GetIt`-powered dependency injection (supports async/lazy registrations)
- Controller abstraction for modular route registration
- Optional isolated containers for mounting self-contained sub-apps
- Batteries-included middleware for CORS, rate limiting, and cookie parsing

## Quick start

```bash
dart pub add fletch
```

```dart
import 'dart:io';

import 'package:fletch/fletch.dart';

Future<void> main() async {
  final app = Fletch();

  app.use(app.cors(allowedOrigins: ['http://localhost:3000']));
  app.get('/health', (req, res) => res.text('OK'));

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await app.listen(port);
  print('Listening on http://localhost:$port');
}
```

## Routing essentials

- Use `app.get`, `app.post`, etc. to register handlers. Supply optional
  middleware with the `middleware:` argument.
- Controllers help organise routes:

  ```dart
  class UsersController extends Controller {
    @override
    void registerRoutes(ControllerOptions options) {
      options.get('/', _list);
      options.get('/:id(\\d+)', _show);
    }
  }

  app.useController('/users', UsersController());
  ```

- Throw one of the built-in `HttpError` types (`NotFoundError`,
  `ValidationError`, etc.) to short-circuit with a specific status code.

## Working with dependencies

The container is backed by `GetIt`. Register dependencies during startup and
retrieve them in handlers via `request.container`:

```dart
app.registerLazySingleton(() => Database(config));

app.get('/posts', (req, res) async {
  final db = req.container.get<Database>();
  final posts = await db.posts();
  res.json({'data': posts});
});
```

## Isolated modules

`IsolatedContainer` lets you mount a self-contained sub-application that has its
own middleware, router, and DI scope while sharing the main server:

```dart
final admin = IsolatedContainer(prefix: '/admin');
admin.use((req, res, next) {
  res.setHeader('X-Isolated', 'admin');
  return next();
});
admin.get('/', (req, res) => res.text('Admin dashboard'));
admin.mount(app);
```

For integration testing or microservice setups you can host the isolated module
by itself:

```dart
await admin.listen(9090); // optional
```

## Real-time with SSE

Server-Sent Events enable real-time server-to-client streaming:

```dart
app.get('/events', (req, res) async {
  await res.sse((sink) async {
    // Send events
    await sink.sendEvent('Welcome!', type: 'greeting');
    
    for (var i = 0; i < 10; i++) {
      await sink.sendEvent('Event $i', id: '$i');
      await Future.delayed(Duration(seconds: 1));
    }
  }, keepAlive: Duration(seconds: 30));
});
```

## Streaming responses

Stream files or chunked data efficiently:

```dart
// Stream a file
app.get('/download/:filename', (req, res) async {
  final filename = req.params['filename']!;
  final file = File('uploads/$filename');
  
  await res.stream(
    file.openRead(),
    contentType: 'application/octet-stream',
  );
});

// Stream generated data
app.get('/data', (req, res) async {
  final stream = Stream.periodic(
    Duration(milliseconds: 100),
    (i) => utf8.encode('chunk-$i\n'),
  ).take(50);
  
  await res.stream(stream, flushEachChunk: true);
});
```

## Example project

See [`example/fletch_example.dart`](example/fletch_example.dart) for
a full reference that demonstrates controllers, isolated modules, and common
middleware.

## Error handling

Install a global error handler to customise responses:

```dart
app.setErrorHandler((error, req, res) async {
  if (error is ValidationError) {
    res.json({'error': error.message, 'details': error.data},
        statusCode: error.statusCode);
    return;
  }

  res.setStatus(HttpStatus.internalServerError);
  res.json({'error': 'Internal Server Error'});
});
```

## Performance tips

- Deploy behind a reverse proxy (nginx, Caddy) that terminates TLS and handles
  static assets.
- Reuse the same `Fletch` instance across isolates if you need more CPU
  headroom—each isolate can call `await app.listen(port, address: ...)` with a
  different binding.
- For load testing use tools like [`wrk`](https://github.com/wg/wrk) or
  [`hey`](https://github.com/rakyll/hey)`:

  ```bash
  wrk -t8 -c256 -d30s http://localhost:8080/health
  ```

  Test both direct routes and isolated modules to compare overhead.
- Request parsing currently buffers the entire body; set upstream limits (e.g.
  via load balancer) and prefer streaming uploads for very large payloads.


## Documentation

Full documentation is available at **[docs.fletch.mahawarkartikey.in](https://docs.fletch.mahawarkartikey.in/)**.

## Community

Join the discussion! We have a dedicated Discord server for:
- 🆘 **Help & Support** - Get answers to your Fletch questions
- 💡 **Ideas & Feedback** - Help shape the future of the framework
- 📢 **Announcements** - Be the first to know about new releases

👉 **[Join our Discord Server](https://discord.gg/KcYqdtxK)**

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Run `dart format .` and `dart analyze`
4. Add tests for new features
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

File issues or feature requests in the [repository issue tracker](https://github.com/kartikey321/fletch/issues).

## License

MIT License.
