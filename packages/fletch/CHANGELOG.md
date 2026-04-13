# Changelog

All notable changes to fletch will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0] - 2026-04-14

### Performance

- **47,104 RPS** on Apple M-series — now within **1.5% of raw `dart:io`**, up from ~10% behind in
  2.2.0.
- **RadixRouter structural refactor** — replaced single `children: Map<String, RadixNode>` with
  four typed slots (`staticChildren`, `regexParamChildren`, `wildcardParamChildren`, `globChild`).
  Eliminates `.values` Iterable allocations on every route lookup. Static children use O(1) HashMap;
  dynamic children use typed lists; all slots are lazily allocated (null until first use).
- **`Response.send` de-async** — removed the `async` keyword from the common (non-streaming) path.
  `httpResponse.close()` is now returned directly, eliminating one Future state machine allocation
  per request.
- **Removed redundant `.then<void>((_) {})` chain** in `_handleRequestWithTimeout` — saved one
  pointless Future allocation per request.

### Added

- **Optional route parameters** (`:id?`) — expanded at `addRoute` time into all concrete path
  combinations (e.g. `/users/:id?` registers both `/users/:id` and `/users`). Zero runtime cost;
  no extra branching during lookup. Supports regex-constrained optionals (`:id(\\d+)?`).
- **Named catch-all glob** (`*:name`) — captures all remaining path segments into `req.params`
  (e.g. `/files/*:path` captures `images/2024/photo.jpg` as `path`). Unnamed `*` continues to
  work as before.

### Fixed

- **`response.send()` never awaited** — all four call sites in `base_container.dart` and
  `fletch.dart` (CORS preflight, CORS forbidden, CORS method-not-allowed, normal response flush)
  now properly `await` the send Future. Previously, errors from `httpResponse.close()` (e.g.
  client disconnect, broken pipe) were silently swallowed.

### Removed

- Dead methods `_RoutePattern.matches`, `_RoutePattern.extractParams`, `_RouteEntry.matches`,
  `_RouteEntry.extractParams` from `ListRouter` — never called; `tryMatch` handles all matching.
- Unreachable `StateError` for short `sessionSecret` in `_validateConfig` — `SessionSigner`
  throws `ArgumentError` in the constructor before this code could ever run.

### Tests

- **318 tests, 97.0% line coverage** (up from 290 tests / 93.6% in 2.2.0).
- New groups: optional params, named glob catch-all, router backtracking, regex node reuse,
  cookie lazy parsing, multipart payload caching, CORS error handling, `IsolatedContainer`
  delegate routing.

## [2.2.0] - 2026-03-15

### Performance

- **44,277 RPS** on Apple M-series — now the fastest Dart web framework, ~10% behind raw `dart:io`.
- **Lazy session & request ID generation** — `Random.secure()` tokens are created only on first
  access. Routes that never touch a session or request ID pay zero entropy cost.
- **Session I/O gated on access** — session load, save, and `Set-Cookie` are skipped entirely for
  routes that never read or write `req.session`.
- **`requestTimeout: null`** — disables the per-request `Timer` allocation (~7k RPS gain).
  Recommended behind load balancers that enforce their own upstream timeout.
- **Static fused JSON encoder** — `JsonUtf8Encoder` reused across requests, eliminating a `String`
  intermediate on every `res.json()` call.
- **Lazy response headers map** — allocated only when headers are actually set.
- **Zero-middleware fast path** — routes with no middleware bypass the closure chain entirely.
- **Radix router** — static cached `RegExp`, combined method-check + regex + param extraction in a
  single pass, early exit after static segment match.
- **Lazy query param parsing** — parsed on first access, not on every request construction.

### Added

- **`session.regenerate()`** — invalidates the current session ID and issues a fresh one. Prevents
  session fixation attacks. Should be called after every successful login. Idempotent within a
  single request.
- **`MultipartFile.sanitizedFilename`** — extension getter that strips all path components from
  attacker-controlled upload filenames (`../../etc/passwd` → `passwd`). Use instead of
  `file.filename` when writing to disk.
- **`Fletch(debug:)`** — when `false` (default), error responses return only
  `"Internal Server Error"`, preventing exception strings from leaking internal details. Set to
  `true` during local development to see full messages.
- **`MemorySessionStore(maxSessions:)`** — caps live session count (default 10,000). Oldest
  entries are evicted on insert when the limit is reached, bounding memory under sustained traffic.
- **CI: `.github/workflows/ci.yml`** — runs `dart analyze --fatal-infos`, full test suite,
  enforces ≥90% line coverage, and uploads to Codecov on every push/PR to `main`.
- **CI: `.github/workflows/mutation.yml`** — weekly `dart_mutant` mutation testing run with HTML,
  JUnit, and AI reports as artifacts. Manually triggerable with configurable sample and threshold.

### Security

- **Session fixation** — `session.regenerate()` destroys the pre-auth session ID at login.
- **Error redaction** — `debug: false` (default) prevents internal exception details from reaching
  clients.
- **Memory exhaustion** — `MemorySessionStore` now evicts oldest sessions at capacity instead of
  growing without bound.
- **Cookie prefix-confusion** — parser now splits on `;` and does exact name matching, so a cookie
  like `evilapp.sid=x;fletch.sid=real` (no space) correctly resolves to `real`.
- **File upload path traversal** — `sanitizedFilename` strips directory components from filenames.
- **Rate limiter proxy bypass** — `keyGenerator` parameter documented with `X-Forwarded-For`
  pattern and explicit warning against trusting unvalidated forwarded headers.

### Fixed

- Race condition in server lifecycle test: replaced fixed 50 ms delay with a `started` completer
  so `close()` is only called once the handler is confirmed in-flight.
- All `dart analyze --fatal-infos` warnings resolved (unused imports, unused variables,
  duplicate field override, super-parameter style).
- `benchmark/` folder excluded from static analysis to prevent dartmark noise locally.

### Tests

- **286 tests, 94.9% line coverage.**
- New test files: `cors_test`, `error_handler_test`, `fletch_features_test`, `rate_limiter_test`,
  `tls_test`, `security_test`, `list_router_test`, `response_test`, `coverage_gaps_test`,
  `coverage_extension_test`.
- TLS integration tests use runtime `openssl` cert generation — no private keys in source.
- Mutation testing: 96.7% kill rate on security-critical paths.

### Documentation

- `configuration.md` — `debug`, `requestTimeout: null`, and `MemorySessionStore(maxSessions:)`
  added to options table and dedicated sections.
- `sessions.md` — `session.regenerate()` replaces the outdated `session.clear()` login pattern;
  full auth example updated; `maxSessions` shown in `MemorySessionStore` example.
- `requests-responses.md` — `sanitizedFilename` shown in the file upload section with path
  traversal warning.
- `server-transport.md` — `requestTimeout: null` performance tip added.
- `security/cors.md` — new Rate Limiting section covering `keyGenerator`, `X-Forwarded-For`
  pattern, and proxy spoofing warning.

## [2.1.0] - 2026-02-26

### Added

- **`listenSecure(port, SecurityContext, {...})`** — binds an `HttpServer` over TLS natively,
  supporting `requestClientCertificate`, `shared`, `backlog`, and `v6Only`.
- **`serveWith(HttpServer)`** — attaches Fletch to a pre-created `HttpServer`, enabling Unix
  sockets, custom TLS configurations, and external server lifecycle management (e.g. tests,
  `server_native` Rust transport).
- **Low-level bind options on `listen()`** — `backlog` and `v6Only` parameters are now
  forwarded to `HttpServer.bind()`.
- **Parity in `IsolatedContainer.listen()`** — `shared`, `backlog`, and `v6Only` added for
  consistency with the main `Fletch.listen()`.
- **13 new tests** covering `serveWith` routing, middleware, error handling, `waitUntilClosed`,
  multi-server scenarios, and `listen()` bind options.

## [2.0.6] - 2026-02-22

### Fixed
- **Publishing & Repository**
  - Removed internal development tools from the published package.
  - Fixed a duplicate package history notice in the `README.md` and removed the `switch_readme.sh` pub.dev injection script.

## [2.0.5] - 2026-02-22

### Changed
- **Dependencies**
  - Updated to latest compatible dependency versions.
  - Added new examples to documentation.


## [2.0.4] - 2026-01-01

### Added
- **Unified Controller Support**
  - Moved `useController` to `BaseContainer`, enabling controllers in both `Fletch` apps and `IsolatedContainer` modules.
  - Added documentation example for `BaseContainer.useController`.

### Changed
- **Refactoring**
  - `Controller.initialize` now accepts `BaseContainer` instead of `Fletch`, allowing for more flexible controller reuse.
  - Removed duplicate `useController` implementation from `Fletch` class (now inherited).

### Documentation
- Significant overhaul of documentation site:
  - Added new "Configuration" guide.
  - Added "Requests & Responses" API reference.
  - Updated "Routing" and "Error Handling" guides.
  - Implemented SEO basics (sitemap, meta tags).

## [2.0.3] - 2025-12-30

### Added
- **Simplified Mounting API**
  - Added `Fletch.mount(String prefix, IsolatedContainer container)` convenience method.
  - Allows easy mounting of isolated containers with automatic prefix handling: `app.mount('/auth', authModule)`.
- **IsolatedContainer Extensions**
  - Added `withPrefix(String newPrefix)` method to support easy re-mounting and configuration of containers.
- **Flexible Response Encoding**
  - Added an optional `Encoding encoding` parameter to `Response` helper methods (`json`, `text`, `html`, `xml`).
  - Defaults to `utf8` but allows overriding for specific needs (e.g., legacy systems).

### Fixed
- **Unicode Response Crash**
  - Fixed an issue where the default encoding (Latin1) caused crashes when sending Unicode characters (like emojis 🔒, ✅) in responses.
  - All response helpers (`json`, `html`, etc.) now explicitly set `charset=utf-8` in the `Content-Type` header by default.

## [2.0.2] - 2025-01-27

### Added
- **Server-Sent Events (SSE)** - `Response.sse()` for real-time server-to-client streaming
  - `SSESink` class with `sendEvent()`, `sendComment()`, keep-alive support
  - Example: `example/sse_example.dart`
- **Generic streaming** - `Response.stream()` for streaming files and data
  - Optional `flushEachChunk` for real-time delivery
  - Example: `example/stream_example.dart`
- **Response utility** - `Response.status()` chainable status code setter
- **HEAD HTTP method** - Added `RequestTypes.HEAD` constant and `head()` method
  - Available in `Fletch`, `IsolatedContainer`, and `BaseContainer`
- Integration tests for SSE and streaming (16 tests, all passing)

### Changed
- **HTTP method refactoring** - Moved HTTP method handlers to `BaseContainer`
  - Eliminated code duplication between `Fletch` and `IsolatedContainer`
  - All HTTP methods (get, post, put, patch, delete, head, options) now inherited from base
  - `IsolatedContainer` overrides `addRoute()` for path normalization
- `Response.send()` is now `Future<void>` (was `void`) - all call sites updated to `await`
- Stream cleanup with try-finally blocks to prevent socket leaks
- Using `httpResponse.headers.chunkedTransferEncoding = true` instead of manual headers
- Mutual exclusion between `stream()`, `sse()`, and `body`/`bytes` responses

### Fixed
- Unawaited futures in `base_container.dart` and `fletch.dart`
- `SSESink.sendComment()` is now `Future<void>` for proper error propagation
- Keep-alive errors using `unawaited()` for fire-and-forget operations

## [2.0.1] - 2025-01-23

### Documentation
- Added Fletch logo to README with baseline alignment
- Improved README visual presentation

## [2.0.0] - 2025-01-22

### 💥 BREAKING CHANGES - Complete Package Repurposing

**This package has been completely repurposed from a jQuery-like library to an Express-inspired HTTP framework.**

#### Package History

- **Versions 0.1.0 - 0.3.0** (2014): jQuery-like library by [Rob Kellett](https://github.com/RobKellett)
- **Version 2.0.0** (2025): Express-inspired HTTP framework by Kartikey Mahawar

Thank you to Rob Kellett for graciously transferring the package name to enable this new project!

#### For Users of the Original Library (v0.3.0)

If you were using the jQuery-like library:
- **Version 0.3.0 remains available**: https://pub.dev/packages/fletch/versions/0.3.0
- **Original repository**: https://github.com/RobKellett/Fletch
- **Pin your version** in `pubspec.yaml`:
  ```yaml
  dependencies:
    fletch: 0.3.0
  ```

#### What's New in 2.0.0

This is a completely new HTTP framework with:

- **Express-like API**: Familiar `app.get()`, `app.post()`, middleware patterns
- **Production-ready**: HMAC-signed sessions, CORS, rate limiting
- **Fast routing**: Radix-tree router with path parameters
- **Dependency injection**: GetIt-powered DI container
- **Modular design**: Controllers, isolated containers
- **Comprehensive docs**: https://docs.fletch.mahawarkartikey.in/

### Features

- ✅ Express-inspired routing and middleware
- ✅ Built-in session management with HMAC signing
- ✅ CORS and rate limiting middleware
- ✅ Request/response helpers (`req.params`, `res.json()`)
- ✅ Error handling with custom error types
- ✅ Graceful shutdown support
- ✅ 98 passing tests
- ✅ Full TypeScript-like type safety

### Documentation

- **Homepage**: https://docs.fletch.mahawarkartikey.in/
- **GitHub**: https://github.com/kartikey321/fletch
- **Examples**: See `/example` directory

---

## [0.3.0] - 2014-07-26 (Original Package by Rob Kellett)

jQuery-like library for Dart. See [original repository](https://github.com/RobKellett/Fletch) for details.

---

## [1.0.0] - 2024-12-13 (Internal Development Version)

### 🔒 Security Enhancements
- **Added HMAC-SHA256 session signing**: Session cookies are now cryptographically signed to prevent tampering
- **Changed session cookie defaults**: Now use `secure: true`, `httpOnly: true`, `SameSite: Lax` by default
- **Added constant-time signature comparison**: Protection against timing attacks
- **Fixed rate limiter memory leak**: Cleanup timers now properly disposed on shutdown

### ✨ New Features
- **Pluggable Session Stores**: Abstract `SessionStore` interface for custom persistence backends
- **MemorySessionStore**: Built-in in-memory store with automatic TTL expiration
- **Session lifecycle hooks**: Automatic load/save with error handling
- **`sessionSecret` parameter**: Configure HMAC secret for production
- **`secureCookies` parameter**: Control HTTPS enforcement (default: `true`)
- **`sessionStore` parameter**: Use Redis, PostgreSQL, or custom backends

### 🔧 Bug Fixes
- Fixed cookie parser discarding empty cookie values (e.g., `logout=`)
- Fixed rate limiter cleanup timer memory leak
- Removed broken `Session.regenerate()` method (session ID is immutable)
- Added proper resource cleanup on server shutdown

### 💥 BREAKING CHANGES
- **Session cookies now require HTTPS in production** (default `secure: true`)
  - Set `secureCookies: false` for local HTTP development
  - Ensure HTTPS is configured for production deployments

### Dependencies
- Added: `crypto: ^3.0.3`
