# Performance, Security & Quality — Full Overhaul

## Benchmark

| | Before | After |
|---|---|---|
| **Fletch RPS** | ~28,500 | **44,277** |
| **vs dart:io** | −42% | **−9.5%** |
| **Ranking** | Last among Dart frameworks | **#1 among all Dart frameworks** |

p50 latency dropped from 0.27 ms → **0.17 ms**. Memory held steady at ~18.4 MB.

---

## Performance Changes

### Lazy ID generation (biggest single regression fix)

Session IDs and request IDs were previously generated eagerly on every request using `Random.secure()` — 36 bytes of OS entropy consumed even for routes that never touch sessions. Benchmark routes paid ~2.9 µs per request for IDs that were immediately thrown away.

Both are now generated lazily — **only on first access**. Routes that skip `req.session` and `req.requestId` pay exactly zero.

```dart
// Session ID — generated on first req.session access only
_sessionId ??= _generateSessionId();

// Request ID — generated on first req.requestId access only
String get requestId => _requestId ??= _generateRequestId();
```

### Nullable `requestTimeout` — remove per-request Timer

`requestTimeout: null` disables the 30s timeout entirely. This removes a `Timer` + `Future` + two closure allocations per request — the single largest throughput improvement (~7k RPS).

Environments with external timeout enforcement (nginx, load balancers) should use `null` in production.

### Lazy session object + `sessionTouched` gate

The `Session` object, all store I/O, and `Set-Cookie` emission are now gated behind a single `sessionTouched` boolean. Routes like `/health` and `/api/echo` pay zero session overhead.

### Zero-middleware fast path

When no global or route-level middleware is registered, `wrapWithMiddleware` short-circuits directly to the handler — no closure or index variable allocations.

### Fused JSON encoder

`res.json()` now uses a static `JsonUtf8Encoder` that encodes directly to `Uint8List` in one step, removing the intermediate `String` allocation per JSON response.

### Lazy maps everywhere

- `req.query` — `Uri.queryParameters` only called on first access
- `res.headers` — `LinkedHashMap` only allocated when a custom header is set
- `RouteMatch.pathParams` — static routes share a single `const {}` map

### Router hot-path improvements

- RadixRouter: static `RegExp` fields, normalization removed from `findRoute`, `List processed` allocation eliminated
- ListRouter: `tryMatch()` does one regex pass instead of two; prefix boundary fix prevents `/api` matching `/apix/...`

---

## Security Fixes

### Error response leaks internal details  `HIGH`

**Before:** Any unhandled exception sent `error.toString()` to the client — leaking DB connection strings, file paths, library internals.

**After:** Generic `"Internal Server Error"` by default. Opt in to full detail with `Fletch(debug: true)` for local development only.

### Session fixation  `HIGH`

**Before:** No way to change session ID after login — attacker could fix a known ID before authentication.

**After:** `await req.session.regenerate()` — destroys the old session record, generates a new cryptographically-random ID, and emits a new `Set-Cookie` automatically.

```dart
app.post('/login', (req, res) async {
  if (await validate(req)) {
    await req.session.regenerate(); // call before writing user data
    req.session['userId'] = user.id;
  }
});
```

### Session IDs were predictable counters  `HIGH`

**Before:** `ses_<microsecond-prefix>_<n>` — sequential, enumerable.

**After:** `ses_<32-char base64url>` — 192 bits from `Random.secure()`, generated lazily.

### Cookie prefix-confusion attack  `HIGH`

**Before:** `indexOf('sessionId=')` matched `evilSessionId=x` and stopped at the first occurrence, missing the real cookie.

**After:** Split-on-`;` parser with exact name comparison — correctly skips prefixed cookies and finds the real session cookie regardless of order.

### `MemorySessionStore` — unbounded memory  `MEDIUM`

**Before:** No size cap — ~86,400 sessions/day at 1 req/sec with no eviction.

**After:** `maxSessions` cap (default 10,000) with oldest-first eviction on insert.

### Rate limiter ineffective behind reverse proxies  `MEDIUM`

Documented clearly with a `keyGenerator` example that reads `X-Forwarded-For` safely, including the trust warning.

### Multipart filename path traversal  `LOW`

`MultipartFile.filename` is attacker-controlled and may contain `../../etc/passwd`. New `sanitizedFilename` extension strips all path components:

```dart
final safe = file.sanitizedFilename; // 'avatar.png', never '../secret'
```

---

## Tests

| | Before | After |
|---|---|---|
| Total tests | ~170 | **286** |
| Coverage | — | **94.9%** |
| Mutation score | — | **96.7%** |

### New test files

| File | Coverage |
|---|---|
| `test/integration/tls_test.dart` | `listenSecure()` IPv4 binding, `v6Only` default, client cert default |
| `test/integration/cors_test.dart` | CORS preflight, origin allowlist, method gating |
| `test/integration/error_handler_test.dart` | Custom handler, session store resilience |
| `test/integration/rate_limiter_test.dart` | Limit enforcement, window reset |
| `test/integration/fletch_features_test.dart` | Full lifecycle: DI, sessions, middleware, errors |
| `test/unit/list_router_test.dart` | All `ListRouter` branches including isolated prefix boundary |
| `test/unit/response_test.dart` | All `Response` methods |
| `test/unit/coverage_gaps_test.dart` | Session store, DI, multipart caching, SSE |
| `test/unit/coverage_extension_test.dart` | Cookie parsing edge cases, `sanitizedFilename`, `regenerate()` |
| `test/security/security_test.dart` | Error redaction, `regenerate()`, ID entropy, `maxSessions` eviction, `sanitizedFilename` |

### Mutation testing

Ran [dart_mutant](https://dartmutant.dev) against all security-critical paths. **96.7% of mutations killed** on the targeted files — the only survivor was a default boolean in `listenSecure()`, now covered by the new TLS integration tests.

---

## CI

### `ci.yml` — runs on every push to `main` and all PRs

1. `dart analyze --fatal-infos`
2. `dart test --coverage`
3. Enforce **≥ 90% line coverage** (currently 94.9%)
4. Upload to Codecov

### `mutation.yml` — weekly scheduled job (Mondays 03:00 UTC)

- 50% mutation sample, `--threshold 75`
- Outputs HTML dashboard, JUnit XML, and AI-optimized markdown report as artifacts
- Manually triggerable from the Actions tab with configurable sample size and threshold

---

## Breaking Changes

None. All public API is backwards-compatible.

- `debug` parameter added to `Fletch()` — defaults to `false`
- `maxSessions` parameter added to `MemorySessionStore()` — defaults to `10000`
- `session.regenerate()` is a new method — no existing code affected
- `MultipartFileExtension.sanitizedFilename` is additive

---

## Files Changed

```
28 files changed, 3,569 insertions(+), 140 deletions(-)

lib/src/models/request.dart              — lazy IDs, secure tokens, cookie parser, regenerate(), sanitizedFilename
lib/src/models/response.dart             — fused JSON encoder, lazy headers
lib/src/models/memory_session_store.dart — maxSessions cap + eviction
lib/src/services/base_container.dart     — sessionTouched gate, debug flag, regeneration cookie
lib/src/services/fletch.dart             — nullable timeout, debug flag, rate limiter docs
lib/src/router/radixRouter/              — static RegExp, hot-path normalization skip, no processed list
lib/src/router/listRouter/               — tryMatch() single-pass, prefix boundary fix
lib/src/router/router_interface.dart     — shared const empty pathParams
.github/workflows/ci.yml                 — new: analyze + test + coverage + Codecov
.github/workflows/mutation.yml           — new: weekly mutation testing
test/integration/tls_test.dart           — new
test/integration/cors_test.dart          — new
test/integration/error_handler_test.dart — new
test/integration/rate_limiter_test.dart  — new
test/integration/fletch_features_test.dart — new
test/unit/list_router_test.dart          — new
test/unit/response_test.dart             — new
test/unit/coverage_gaps_test.dart        — new
test/unit/coverage_extension_test.dart   — new
test/security/security_test.dart         — expanded
```
