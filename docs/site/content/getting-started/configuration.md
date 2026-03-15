# Configuration

Fletch is designed with sane defaults but offers extensive configuration options for production deployments.

## The Fletch Constructor

Pass configuration options directly to the `Fletch` constructor:

```dart
final app = Fletch(
  sessionSecret: Platform.environment['SESSION_SECRET'],
  secureCookies: true,
  maxBodySize: 20 * 1024 * 1024, // 20 MB
);
```

### Essential Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `sessionSecret` | `String?` | `null` | Secret key (min 32 chars) used to sign session cookies. **Required** for secure sessions. |
| `secureCookies` | `bool` | `true` | If true, session cookies are marked `Secure` (HTTPS only). Set to `false` for local dev. |
| `sessionStore` | `SessionStore?` | `MemorySessionStore` | Backend for session data. Use `MemorySessionStore` for dev, external store for prod. |
| `maxBodySize` | `int` | `10 MB` | Limit for parsed request bodies (JSON, text, etc). Throws 413 if exceeded. |
| `maxFileSize` | `int` | `100 MB` | Limit for file uploads. Throws 413 if exceeded. |
| `requestTimeout` | `Duration?` | `30s` | Max execution time for request handlers. Throws 408 on timeout. Set to `null` to disable. |
| `debug` | `bool` | `false` | When `true`, full exception details appear in error responses. **Never enable in production.** |

## Session Configuration

### Session Secret

For production, you **must** provide a strong, random session secret. The framework enforces a minimum length of 32 characters.

```bash
# Generate a secret
openssl rand -base64 48
```

```dart
final app = Fletch(
  sessionSecret: Platform.environment['SESSION_SECRET']!,
);
```

If `sessionSecret` is omitted, sessions will be unsigned and potentially vulnerable to tampering.

### Session Stores

By default, Fletch uses an in-memory store. This is perfect for development but unsuitable for production because:
1. Data is lost on server restart.
2. It's not shared across multiple server instances.
3. It consumes server RAM.

The in-memory store caps at 10,000 live sessions by default, evicting the oldest when the limit is reached. Raise or lower this to match your expected load:

```dart
final app = Fletch(
  sessionStore: MemorySessionStore(maxSessions: 50000),
);
```

For production, implement `SessionStore` using Redis, PostgreSQL, or Mongo:

```dart
class RedisSessionStore implements SessionStore {
  // Implementation...
}

final app = Fletch(
  sessionStore: RedisSessionStore(redisClient),
);
```

## Limits and Timeouts

### Request Body Limits

Prevent DoS attacks by limiting payload sizes:

```dart
final app = Fletch(
  // Increase limit for large JSON payloads
  maxBodySize: 50 * 1024 * 1024, // 50 MB
  
  // Increase limit for file uploads
  maxFileSize: 500 * 1024 * 1024, // 500 MB
);
```

### Timeouts

Ensure your server stays responsive by enforcing timeouts:

```dart
final app = Fletch(
  // Kill requests that take too long
  requestTimeout: Duration(seconds: 15),

  // Wait for active requests to finish during shutdown
  shutdownTimeout: Duration(seconds: 60),
);
```

Set `requestTimeout: null` to disable handler timeouts entirely. This eliminates the per-request `Timer` allocation and can measurably improve throughput when your load balancer or reverse proxy already enforces its own timeout:

```dart
final app = Fletch(
  requestTimeout: null, // rely on nginx/ALB timeout instead
);
```

### Debug Mode

Enable full error details during local development:

```dart
// Development
final app = Fletch(debug: true);

// Production (default — redacts internal error messages)
final app = Fletch(debug: false);
```

With `debug: false` (the default), error responses contain only a generic `"Internal Server Error"` message. With `debug: true`, the actual exception string is included, which is useful for debugging but **must never be used in production** — exception messages can leak connection strings, file paths, and other internal details.

## Advanced Options

### Logger

Fletch uses `package:logger`. You can pass your own instance to customize output:

```dart
import 'package:logger/logger.dart';

final app = Fletch(
  logger: Logger(
    printer: PrettyPrinter(methodCount: 0),
    level: Level.info,
  ),
);
```

### Cookie Parsing

By default (`useCookieParser: true`), Fletch automatically parses the `Cookie` header into `req.cookies`. You can disable this if you prefer a custom parser:

```dart
final app = Fletch(useCookieParser: false);
```

### Dependency Injection

Fletch uses `GetIt` internally. You can pass an existing container if you are integrating with other parts of your app:

```dart
final app = Fletch(container: GetIt.I);
```

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/getting-started/quick-start" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🚀 Quick Start</span>
  </a>
  <a href="/core-concepts/requests-responses" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>Reqs & Resps</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
