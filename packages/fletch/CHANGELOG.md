# Changelog

All notable changes to fletch will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
