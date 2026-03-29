### Description

We recently ran benchmarks integrating `server_native` into the [Fletch](https://pub.dev/packages/fletch) web framework. While `server_native` offers excellent single-thread performance (reaching ~9.5k req/s with fantastic p99 tail latencies on our test machine), we noticed that it **does not scale when combined with Dart's multi-isolate `shared: true` pattern**. 

By comparison, `dart:io` scales almost linearly with core count when using isolates (jumping from ~8.6k to ~13k req/s on an 11-core M-series chip). `server_native` remained flat at ~9.5k req/s regardless of isolate count.

This issue outlines the architectural bottlenecks we identified, intended to spark a discussion on potential improvements for scaling with isolates.

---

## The Bottlenecks

We traced the behavior through both the Dart `NativeHttpServer` bindings and the Rust FFI proxy code. We found two primary areas of contention when multiple Dart isolates attempt to bind a `server_native` transport on the same port:

### 1. Tokio Thread-Pool Contention (`O(N * Cores)` Threads)
When `NativeHttpServer.bind` is called, it ultimately invokes the `server_native_start_proxy_server` FFI function. 
Inside the Rust backend, this spins up a dedicated Tokio multi-threaded runtime:

```rust
let worker_threads = std::thread::available_parallelism()
    .map(|value| value.get())
    .unwrap_or(2)
    .clamp(2, 16);
let runtime = tokio::runtime::Builder::new_multi_thread()
    .worker_threads(worker_threads)
    // ...
```

In a standard Dart application using the `shared: true` pattern, a developer spawns `Platform.numberOfProcessors` isolates. 
Because *each* isolate calls `bind`, this results in creating **N separate Tokio runtimes**, each trying to allocate up to 16 threads. 

On an 11-core machine, spawning 11 Dart isolates means creating upwards of **176 active OS threads** in the Rust backend, all contending for CPU time against each other and the Dart event loops. The OS scheduler gets overwhelmed with context switching, and the raw I/O throughput gains are completely lost to thread thrashing.

### 2. The FFI Polling Loop Overhead
In its most performant mode (`nativeCallback: true`, which is the default), `server_native` avoids socket overhead by sending HTTP framing directly over FFI using a tight polling loop on the Dart side:

```dart
// server_boot_proxy_direct.dart
unawaited(() async {
  while (!proxyRef.isClosed) {
    NativeDirectRequestFrame? frame;
    try {
      frame = proxyRef.pollDirectRequestFrame(timeoutMs: 0);
    // ...
```

Because `server_native` has no way to dispatch an FFI callback from a random Rust Tokio thread to a *specific* Dart isolate's event loop (due to Dart isolate memory isolation), it forces each isolate to constantly poll the Rust proxy. 

When you have 11 isolates running this `while` loop simultaneously, a massive amount of CPU cycles are burned just polling the FFI boundary, further starving the actual request handlers of compute time.

*(Note: We tried benchmarking with `nativeCallback: false` so it falls back to Unix/TCP bridge sockets, but the overhead of encoding/deciding bridge frames over sockets brought the max throughput down to ~9.1k req/s, which was slower than the single-isolate `nativeCallback: true` baseline).*

---

## Why this matters

A major selling point of Dart backend development is that `dart:io` makes multi-core scaling trivial: just spawn isolates and let the OS kernel load-balance the `ServerSocket` accepts via `SO_REUSEPORT`.

`server_native` breaks this assumption because it tries to solve the concurrency problem internally via Rust/Tokio, rather than letting the Dart VM handle it at the isolate level.

Currently, developers must choose between:
1. **Raw Throughput:** Use `dart:io` + isolates (Scales linearly, but worse base latency).
2. **Low Latency & Simplicity:** Use `server_native` + single isolate (Great latency, zero isolate state-sharing complexity, but cannot scale vertically across remaining cores).

## Potential Solutions for Discussion

If `server_native` aims to support the Dart multi-isolate pattern, the architecture would likely need a way to share a *single* Rust Tokio runtime across all Dart isolates.

Some ideas:

1. **Singleton Native Runtime:** 
   Can the Rust library detect if a proxy is already running for a given port, and if so, attach to the existing Tokio runtime instead of spanning a new one?
   
2. **Dart SendPort/ReceivePort FFI:**
   Is it possible to pass a native `SendPort` to the Rust backend? This would allow the single Rust I/O thread-pool to blindly dispatch parsed HTTP frames into a shared Dart isolate `ReceivePort`, eliminating the need for each isolate to run a CPU-heavy `while` polling loop.

3. **Explicit "Worker" Mode:**
   Introduce a configuration flag (e.g., `isolateMode: NativeIsolateMode.worker`) that tells `server_native` *not* to boot Tokio or bind sockets, but simply register itself to receive FFI callbacks from a "Primary" server instance booted in the main isolate.

---

## Benchmark Context

These numbers were produced using `wg/wrk` in the open-source Fletch benchmark suite (`apps/fletch_bench`). You can review the benchmarking scripts and reproduce these results by running the [Fletch Benchmark Script](https://github.com/kartikey321/fletch/blob/main/apps/fletch_bench/bench.sh).

**Configuration**: `-t8 -c200 -d30s` on 11-core Apple ARM64

| Metric | dart:io (×1) | dart:io (×11) | native (×1) | native (×11) |
|--------|-------------|--------------|------------|-------------|
| **Throughput (req/s)** | 9,463 | **13,998** | 10,452 | 10,317 |
| **Latency p50** | 10.5ms | **6.5ms** | 9.5ms | 9.5ms |
| **Latency p75** | 10.7ms | **7.6ms** | 9.7ms | 9.7ms |
| **Latency p90** | 10.8ms | **10.1ms** | 9.9ms | 9.9ms |
| **Latency p99** | 14.0ms | 16.8ms | **10.4ms** | 12.8ms |

### Δ vs single-isolate dart:io baseline

| | dart:io ×1 | dart:io ×11 | native ×1 | native ×11 |
|-|-----------|------------|---------|-----------|
| Throughput | — | +47.9% | +10.4% | +9.0% |
| p50 latency | — | −38.2% | −9.5% | −9.5% |
| p99 latency | — | +20.0% | −25.7% | −8.5% |
