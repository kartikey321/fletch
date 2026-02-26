# Fletch HTTP Transport Benchmark

Comparing four server configurations across two transports and two isolate modes,
using [wrk](https://github.com/wg/wrk) as the load generator.

---

## Setup

### Machine

| | |
|---|---|
| **Device** | Apple MacBook (ARM64 / M-series) |
| **Logical CPUs** | 11 |
| **OS** | macOS Darwin 25.1.0 |
| **Dart SDK** | 3.10.0 stable |

### Transports tested

| ID | Transport | Package |
|----|-----------|---------|
| `dart:io` | Standard Dart HTTP server | `dart:io` (stdlib) |
| `native` | Rust-backed HTTP server | [`server_native ^0.1.3+1`](https://pub.dev/packages/server_native) |

Both transports are attached to Fletch via `app.serveWith(server)`, meaning all
routing, middleware, session and error-handling logic is identical — only the
underlying I/O runtime differs.

### Isolate modes

| Mode | Description |
|------|-------------|
| Single | One Dart isolate, one server instance |
| Multi (11) | `Platform.numberOfProcessors` isolates, all bound with `shared: true` |

In multi-isolate mode the OS kernel distributes accepted connections across all
isolates using its internal accept load-balancer.

### Endpoint

```
GET /bench  →  {"transport":"...","ok":true}   (Content-Type: application/json)
```

A minimal JSON route with no database or I/O — measures pure HTTP dispatch overhead.

---

## Running the benchmark yourself

### Prerequisites

```bash
brew install wrk     # macOS
# or
apt install wrk      # Debian/Ubuntu
```

Dart SDK 3.6+ required.

### Steps

```bash
cd apps/fletch_bench
dart pub get

# Full 4-way comparison (≈ 2.5 min with defaults)
./bench.sh

# Custom load / duration
./bench.sh -t 8 -c 200 -d 30s

# Isolates only (faster)
./bench.sh -s -t 8 -c 200 -d 30s
```

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-t <n>` | 4 | wrk threads |
| `-c <n>` | 100 | concurrent connections |
| `-d <s>` | 30s | benchmark duration per run |
| `-w <s>` | 5s | warmup duration per run |
| `-p <n>` | 0 | bind port (0 = OS-assigned) |
| `-s` | off | skip single-isolate runs |

### How it works internally

1. **`dart build cli`** compiles all four server scripts to AOT native executables
   (includes Rust build hook for `server_native`).
2. Each server is started in the background; `bench.sh` waits for `READY port=N` on stdout.
3. wrk runs a warmup pass, then a measured pass with `--latency`.
4. The server is killed and the next one starts.
5. Results are parsed from wrk output and displayed in a comparison table.

---

## Results

**Configuration**: `-t8 -c200 -d30s` on 11-core Apple ARM64

| Metric | dart:io (×1) | dart:io (×11) | native (×1) | native (×11) |
|--------|-------------|--------------|------------|-------------|
| **Throughput (req/s)** | 8,685 | **12,960** | 9,596 | 9,525 |
| **Latency p50** | 22.2ms | **14.7ms** | 20.2ms | 20.2ms |
| **Latency p75** | 22.7ms | **15.8ms** | 20.6ms | 20.6ms |
| **Latency p90** | 23.9ms | **17.5ms** | 21.2ms | 21.9ms |
| **Latency p99** | 57.9ms | 41.9ms | **41.1ms** | 40.9ms |

### Δ vs single-isolate dart:io baseline

| | dart:io ×1 | dart:io ×11 | native ×1 | native ×11 |
|-|-----------|------------|---------|-----------|
| Throughput | — | +49.2% | +10.5% | +9.7% |
| p50 latency | — | −33.9% | −9.1% | −9.1% |
| p99 latency | — | −27.6% | −29.0% | −29.4% |

**Winner on throughput**: `dart:io` + 11 isolates — 12,960 req/s

---

## Analysis

### dart:io + isolates: best raw throughput

Dart's `HttpServer` with `shared: true` allows N isolates to each run a full
accept-loop on the same port. Because each isolate is truly concurrent (separate
heap, separate event loop), and the OS distributes connections uniformly, throughput
scales close to linearly with core count up to the saturation point.

On this 11-core machine, throughput grew **+49%** vs single-isolate, and p50 latency
dropped **−34%**.

### server_native: best single-threaded tail latency

The Rust runtime handles I/O differently from Dart's — it uses its own async runtime
(Tokio) which likely manages connection concurrency more efficiently at the socket
level. This gives it a **−29% p99** improvement vs single-isolate dart:io with no
code changes beyond `NativeHttpServer.bind(...)`.

### server_native + isolates: flat scaling

Adding Dart isolates on top of `server_native` did not improve throughput (and in fact,
adds overhead). The Rust proxy runs its own async Tokio thread pool that saturates available
I/O capacity internally. Adding more Dart isolates binding to the same port simply creates
N polling Rust runtimes (if `nativeCallback: true`) or socket contention (if `nativeCallback: false`).

The proxy architecture does not currently scale with Dart isolates in the same way `dart:io` does.

---

## Integrating server_native with Fletch

Since `NativeHttpServer` implements `dart:io`'s `HttpServer` interface, it plugs
straight into `serveWith()`:

```dart
import 'package:fletch/fletch.dart';
import 'package:server_native/server_native.dart';

void main() async {
  final app = Fletch();

  app.get('/', (req, res) => res.json({'ok': true}));

  final server = await NativeHttpServer.bind(InternetAddress.anyIPv4, 3000);
  await app.serveWith(server);
  print('Running on port ${server.port}');
}
```

Add to `pubspec.yaml`:

```yaml
dependencies:
  fletch: ^2.1.0
  server_native: ^0.1.3+1
```

---

## Recommendations

| Use case | Config |
|----------|--------|
| Dev / simple API | `app.listen(port)` |
| Multi-core production (highest throughput) | `app.listen(port, shared: true)` + isolates |
| Low tail-latency, single thread | `app.serveWith(NativeHttpServer.bind(...))` |
| mTLS / custom TLS | `app.listenSecure(port, SecurityContext(...))` |
| Test harness / Unix socket | `app.serveWith(preCreatedServer)` |

---

## Notes & caveats

- Benchmarks were run on localhost (loopback), eliminating network overhead. Real-world
  numbers over the network will be lower but ratios should hold.
- The endpoint returns a trivial JSON body. Heavier handlers (DB queries, crypto) will
  shift the bottleneck away from the transport layer.
- `server_native` is in preview (`dart build cli` is required for AOT; `dart compile exe`
  does not support native asset build hooks).
- Results reflect a single test run. Re-run with longer `-d` and multiple passes for
  production capacity planning.
