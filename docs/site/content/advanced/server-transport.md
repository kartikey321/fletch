# Server Transport & Binding

Fletch gives you full control over how the underlying `HttpServer` is created and attached.
Beyond the simple `await app.listen(3000)` quick-start, three entry points let you configure
every aspect of the TCP socket, add native TLS, or hand Fletch a pre-built server entirely.

---

## `listen()` — standard HTTP with bind options

```dart
final server = await app.listen(
  3000,
  address: InternetAddress.anyIPv4, // default
  shared: false,   // allow multiple isolates on same port
  backlog: 0,      // OS-chosen listen backlog (0 = OS default)
  v6Only: false,   // IPv6-only socket
);
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `port` | `int` | required | Port to bind. Pass `0` for an OS-assigned ephemeral port. |
| `address` | `InternetAddress?` | `anyIPv4` | Bind address. |
| `shared` | `bool` | `false` | Allow multiple isolates to share the same port. |
| `backlog` | `int` | `0` | Maximum pending connection queue length. |
| `v6Only` | `bool` | `false` | Restrict an IPv6 socket to IPv6 clients only. |

---

## `listenSecure()` — native TLS / HTTPS

Binds directly over TLS without needing a reverse proxy.

```dart
final ctx = SecurityContext()
  ..useCertificateChain('cert.pem')
  ..usePrivateKey('key.pem');

await app.listenSecure(
  443,
  ctx,
  address: InternetAddress.anyIPv4,
  requestClientCertificate: false, // set true for mTLS
);
```

All the same `shared`, `backlog`, and `v6Only` options are available.

> **Tip**: For development, generate a self-signed cert with:
> ```bash
> openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
> ```

---

## `serveWith()` — bring your own server

Pass any pre-created `HttpServer` (or anything that implements it) to Fletch.
This is the escape hatch for:

- **Unix domain sockets**
- **Custom TLS configurations**
- **Alternative transports** (e.g. [`server_native`](https://pub.dev/packages/server_native) for a Rust-backed HTTP runtime)
- **Test harnesses** that manage server lifecycle externally

```dart
// Unix socket
final server = await ServerSocket.bind(
  InternetAddress('/tmp/app.sock', type: InternetAddressType.unix),
  0,
);
await app.serveWith(server as HttpServer);
```

```dart
// Rust-backed transport via server_native
import 'package:server_native/server_native.dart';

final server = await NativeHttpServer.bind(InternetAddress.anyIPv4, 3000);
await app.serveWith(server); // NativeHttpServer implements HttpServer
```

`serveWith()` returns the same server reference so you can keep a handle for `close()` / `waitUntilClosed()`:

```dart
final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
final attached = await app.serveWith(server);

// later…
await app.close();
await app.waitUntilClosed(attached);
```

---

## Multi-isolate scaling

Dart is single-threaded per isolate, but you can saturate all CPU cores by spawning
multiple isolates that all bind with `shared: true`. The OS kernel distributes incoming
connections across them.

```dart
import 'dart:io';
import 'dart:isolate';
import 'package:fletch/fletch.dart';

void _worker(int port) async {
  final app = Fletch(secureCookies: false);
  app.get('/api', (req, res) => res.json({'ok': true}));

  final server = await HttpServer.bind(
    InternetAddress.anyIPv4, port, shared: true,
  );
  await app.serveWith(server);
}

void main() async {
  final app = Fletch(secureCookies: false);
  app.get('/api', (req, res) => res.json({'ok': true}));

  // Bind first to claim the port
  final server = await HttpServer.bind(
    InternetAddress.anyIPv4, 3000, shared: true,
  );

  // Spawn N-1 additional workers (main isolate counts as one)
  final workers = Platform.numberOfProcessors;
  for (var i = 1; i < workers; i++) {
    await Isolate.spawn(_worker, server.port);
  }

  print('Listening on ${server.port} across $workers isolates');
  await app.serveWith(server);
}
```

### Benchmark results (Apple M-series, 11 cores, wrk -t8 -c200 -d30s)

| Transport | Isolates | Req/s | p50 | p99 |
|-----------|----------|-------|-----|-----|
| dart:io | 1 | 8,685 | 22.2ms | 57.9ms |
| **dart:io** | **11** | **12,960** | **14.7ms** | **41.9ms** |
| server_native (Rust) | 1 | 9,596 | 20.2ms | 41.1ms |
| server_native (Rust) | 11 | 9,525 | 20.2ms | 40.9ms |

Key takeaways:
- `dart:io` + isolates yields the highest raw throughput (+49% vs single-isolate dart:io).
- `server_native` delivers lower tail latency at single-isolate — p99 matches the dart:io
  multi-isolate result without any extra complexity.
- `server_native` + isolates shows flat scaling because the Rust runtime already handles
  concurrency internally.

---

## Choosing the right approach

| Scenario | Recommended |
|----------|-------------|
| Simple API, single machine | `app.listen(port)` |
| Multi-core production server | `app.listen(port, shared: true)` + isolates |
| Native HTTPS without a proxy | `app.listenSecure(443, ctx)` |
| Testing / custom lifecycle | `app.serveWith(server)` |
| Lower tail latency, single thread | `serveWith(NativeHttpServer.bind(...))` |

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/advanced/isolated-containers" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🗂 Isolated Containers</span>
  </a>
  <a href="/deployment/docker" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🐳 Docker Deployment</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
