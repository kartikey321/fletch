# AST Integration - Testing Steps

## Benchmark: `hotreloader` vs `fletch_dev_tools`

This repo includes a process-level comparison benchmark script at:

`tool/benchmark_hotreloader_comparison.dart`

It runs both implementations against equivalent synthetic edit workloads and prints:
- human-readable summary (min/p50/p95/max/mean)
- machine-readable JSON line (`JSON_RESULT: ...`)

### Prerequisites

```bash
cd /Users/kartik/StudioProjects/dart_express/packages/fletch_dev_tools
dart pub get
```

### Run benchmark (default)

```bash
dart run tool/benchmark_hotreloader_comparison.dart
```

Default config:
- `runs=5`
- `edits=8`
- `fixture=both` (`body` + `route`)

### Run benchmark (custom)

```bash
dart run tool/benchmark_hotreloader_comparison.dart --runs=3 --edits=10 --fixture=body
dart run tool/benchmark_hotreloader_comparison.dart --runs=3 --edits=10 --fixture=route
dart run tool/benchmark_hotreloader_comparison.dart --runs=3 --edits=10 --fixture=both
```

### How to interpret output

You’ll see blocks like:

- `fletch_dev_tools: n=... p50=... p95=...`
- `hotreloader:      n=... p50=... p95=...`
- `p50 ratio (fletch/hotreloader): X.XXx`

Interpretation:
- ratio `< 1.00x`: `fletch_dev_tools` faster on p50
- ratio `> 1.00x`: `hotreloader` faster on p50

Use both `p50` and `p95`:
- `p50` = typical latency
- `p95` = tail latency / consistency under bursts

### Notes

- This is an end-to-end benchmark (file write → observed reload/restart outcome line).
- `fletch_dev_tools` may use hot reload or restart depending on classification.
- `hotreloader` path measures VM hot reload behavior in-process.
- For stable comparisons, close other CPU-heavy apps and rerun multiple times.

---

## Setup

```bash
# From fletch_dev_tools directory
cd /Users/kartik/StudioProjects/dart_express/packages/fletch_dev_tools
```

## Test 1: Body-Only Change (Should Hot Reload)

1. **Start dev server:**
   ```bash
   dart run bin/fletch.dart --entry example/test_server.dart
   ```

2. **Edit `example/test_server.dart`:**
   - Change message in root route
   - Change version number
   - Add logging statements

3. **Expected output:**
   ```
   📝 File changed: example/test_server.dart
   🔍 Analyzing changes...
      ✅ Function body changed: main [line X]
   🔄 Hot reloading...
   ✅ Hot reload successful (Xms)
   ```

## Test 2: Signature Change (Should Restart)

1. **Edit route handler signature:**
   ```dart
   app.get('/user/:id', (req, res, {bool verbose = false}) {  // Added param
   ```

2. **Expected output:**
   ```
   📝 File changed: example/test_server.dart
   🔍 Analyzing changes...
      ⚠️ Function signature changed: main [line X]
         💡 Restart required - signature change is breaking
   🔄 Hot restarting (Function signature changed: main)...
   🛑 Stopping server...
   ✅ Server stopped
   🚀 Starting server: example/test_server.dart
   ⚡ Restarted in Xms
   ```

## Test 3: Verify with curl

While dev server is running:

```bash
# Test endpoint
curl http://localhost:3003/

# Make body change to test_server.dart
# Verify response changes without restart

# Make signature change
# Verify server restarts
```

## Success Criteria

- ✅ Body changes trigger hot reload (< 200ms)
- ✅ Signature changes trigger restart (~500ms)
- ✅ Server keeps running between changes
- ✅ Changes are reflected immediately
- ✅ Detailed change information shown in console
