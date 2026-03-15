# Fletch

Express-style developer ergonomics, Dart performance, and production-first defaults.

## What you get

- **Familiar API**: `app.use`, `app.get`, `req.params`, `res.json`—if you know Express, you’re at home.
- **Safety built in**: HMAC-signed session cookies, secure-by-default SameSite/HttpOnly, CORS and rate limiting middleware.
- **Performance**: Radix-tree routing, multi-isolate server option for multi-core throughput.
- **Observability**: Request IDs on every response, structured logging hooks.
- **Extensibility**: Pluggable session and rate-limit stores; GetIt DI for your services.

## Install

```bash
dart pub add fletch
```

## Minimal app

```dart
import 'package:fletch/fletch.dart';

Future<void> main() async {
  final app = Fletch(
    sessionSecret: 'change-me-to-a-32+char-random-secret',
  );

  app.get('/', (req, res) => res.text('Hello, Dart!'));

  app.get('/api/users', (req, res) {
    res.json({'users': ['Alice', 'Bob', 'Charlie']});
  });

  await app.listen(3000);
  print('Server running on http://localhost:3000');
}
```

For local HTTP testing, you can set `secureCookies: false` when constructing `Fletch`; keep it `true` in production.

## Production highlights

- **Sessions**: Signed cookies; pluggable `SessionStore` (e.g., Redis) with automatic load/save per request.
- **Security**: Strict CORS configuration, rate limiter, request timeout, graceful shutdown.
- **Error handling**: Fallback error responses if custom handlers fail to write.
- **Multi-core**: `tool/serve_multi.dart` to run one isolate per core on the same port.

## Where to next?

- Start building: [Quick Start](/getting-started/quick-start)
- Learn the basics: [Getting Started](/getting-started/installation)
- Harden it: [Security](/security)
- See it in action: [Examples](/examples)
- API reference: [Core Concepts](/core-concepts)

---

⭐ [GitHub](https://github.com/kartikey321/fletch) • 🐛 Issues • 💬 Discussions (coming soon)
