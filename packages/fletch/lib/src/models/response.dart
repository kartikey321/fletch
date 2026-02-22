import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'sse_sink.dart';

/// Represents an outgoing HTTP response with helpers for common response types.
///
/// Response objects are passed to route handlers alongside [Request] objects.
/// Use the various helper methods to send different types of responses.
///
/// ## Example
///
/// ```dart
/// app.get('/api/user', (req, res) {
///   res.json({'name': 'Alice'}); // JSON response
/// });
///
/// app.get('/page', (req, res) {
///   res.html('<h1>Hello</h1>'); // HTML response
/// });
///
/// app.get('/download', (req, res) async {
///   await res.file(File('data.pdf')); // File download
/// });
/// ```
class Response {
  /// HTTP status code (default: 200).
  int statusCode;

  /// Response body content.
  dynamic body;

  /// Response headers as key-value pairs.
  Map<String, String> headers = {};

  /// Whether the response body is binary data.
  bool isBinary = false;

  bool _isSent = false;
  final List<Cookie> _cookies = [];

  // Streaming fields
  Stream<List<int>>? _streamData;
  bool _isStream = false;
  bool _flushEachChunk = false;

  // SSE-specific fields
  Future<void> Function(SSESink sink)? _sseHandler;
  Duration? _sseKeepAlive;
  bool _isSse = false;

  /// Whether the response has been sent to the client.
  bool get isSent => _isSent;

  Response({this.statusCode = 200, this.body, Map<String, String>? headers}) {
    if (headers != null) {
      this.headers.addAll(headers);
    }
  }

  /// Sets a cookie on the response.
  ///
  /// Cookies with the same [name] and [path] are replaced to avoid duplicates.
  ///
  /// ## Parameters
  ///
  /// - [name]: Cookie name
  /// - [value]: Cookie value
  /// - [expires]: Expiration date (absolute)
  /// - [maxAge]: Expiration in seconds (relative)
  /// - [domain]: Cookie domain
  /// - [path]: Cookie path (default: '/')
  /// - [secure]: HTTPS only (default: true)
  /// - [httpOnly]: No JavaScript access (default: true)
  /// - [sameSite]: CSRF protection (default: Lax)
  ///
  /// ## Example
  ///
  /// ```dart
  /// res.cookie('sessionId', 'abc123',
  ///   maxAge: 3600,
  ///   httpOnly: true,
  ///   secure: true,
  /// );
  /// ```
  void cookie(
    String name,
    String value, {
    DateTime? expires,
    int? maxAge,
    String? domain,
    String? path,
    bool secure = true,
    bool httpOnly = true,
    SameSite? sameSite = SameSite.lax,
  }) {
    final cookie = Cookie(name, value)
      ..expires = expires
      ..maxAge = maxAge
      ..domain = domain
      ..path = path ?? '/'
      ..secure = secure
      ..httpOnly = httpOnly;

    if (sameSite != null) {
      cookie.sameSite = sameSite;
    }

    _replaceCookie(cookie);
  }

  /// Removes a cookie by name.
  ///
  /// Sets an expired cookie to delete it from the client.
  ///
  /// ## Example
  ///
  /// ```dart
  /// res.clearCookie('sessionId');
  /// ```
  void clearCookie(String name, {String? path, String? domain}) {
    final cookie = Cookie(name, '')
      ..maxAge = 0
      ..expires = DateTime.utc(1970)
      ..path = path
      ..domain = domain;
    _replaceCookie(cookie);
  }

  /// Returns `true` when a cookie with the given [name] (and optional [path])
  /// is queued for the response.
  bool hasCookie(String name, {String? path}) {
    return _cookies.any((cookie) {
      if (cookie.name != name) return false;
      if (path == null) return true;
      return (cookie.path ?? '/') == path;
    });
  }

  /// Sends a JSON response.
  ///
  /// Automatically sets Content-Type to application/json.
  ///
  /// ## Example
  ///
  /// ```dart
  /// res.json({'success': true, 'data': users});
  /// res.json({'error': 'Not found'}, statusCode: 404);
  /// ```
  void json(Map<String, dynamic> data,
      {int? statusCode, Encoding encoding = utf8}) {
    // JSON must be encoded to string first
    body = jsonEncode(data);
    headers['Content-Type'] = 'application/json; charset=${encoding.name}';
    if (statusCode != null) {
      setStatus(statusCode);
    }
  }

  /// Writes a plain text payload to the response.
  void text(String data, {int? statusCode, Encoding encoding = utf8}) {
    body = data;
    headers['Content-Type'] = 'text/plain; charset=${encoding.name}';
    if (statusCode != null) {
      setStatus(statusCode);
    }
  }

  /// Writes an HTML payload to the response.
  void html(String html, {int? statusCode, Encoding encoding = utf8}) {
    body = html;
    headers['Content-Type'] = 'text/html; charset=${encoding.name}';
    if (statusCode != null) {
      setStatus(statusCode);
    }
  }

  /// Writes an XML payload to the response.
  void xml(String xml, {int? statusCode, Encoding encoding = utf8}) {
    body = xml;
    headers['Content-Type'] = 'application/xml; charset=${encoding.name}';
    if (statusCode != null) {
      setStatus(statusCode);
    }
  }

  Response status(int code) => this..statusCode = code;

  /// Streams raw bytes to the client using the supplied content-type.
  void bytes(Uint8List bytes,
      {String contentType = 'application/octet-stream', int? statusCode}) {
    body = bytes;
    isBinary = true;
    headers['Content-Type'] = contentType;
    headers['Content-Length'] = bytes.length.toString();
    if (statusCode != null) {
      setStatus(statusCode);
    }
  }

  /// Reads a file from disk and emits it as the response body. Responds with
  /// a 404 when the file does not exist.
  Future<void> file(
    File file,
  ) async {
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      this.bytes(bytes, contentType: _getContentType(file.path));
    } else {
      statusCode = HttpStatus.notFound;
      text('File not found');
    }
  }

  /// Issues an HTTP redirect by setting the appropriate status code and
  /// `Location` header.
  void redirect(String url, {int status = HttpStatus.movedPermanently}) {
    statusCode = status;
    headers['Location'] = url;
  }

  static String _getContentType(String filePath) {
    return lookupMimeType(filePath) ?? 'application/octet-stream';
  }

  /// Streams data to the client.
  ///
  /// Generic streaming for any byte data (files, chunked responses, etc.)
  ///
  /// ## Parameters
  ///
  /// - [data]: Stream of byte chunks to send
  /// - [contentType]: MIME type (default: application/octet-stream)
  /// - [statusCode]: HTTP status code
  /// - [flushEachChunk]: Flush after each chunk for real-time streaming
  ///
  /// ## Example
  ///
  /// ```dart
  /// app.get('/stream', (req, res) async {
  ///   final stream = File('video.mp4').openRead();
  ///   await res.stream(stream, contentType: 'video/mp4');
  /// });
  /// ```
  Future<void> stream(
    Stream<List<int>> data, {
    String contentType = 'application/octet-stream',
    int? statusCode,
    bool flushEachChunk = false,
  }) async {
    if (_isSse) {
      throw StateError('Cannot use stream() after sse() has been called');
    }
    if (_isStream) {
      throw StateError('Stream response already configured.');
    }
    if (body != null || isBinary) {
      throw StateError(
          'Response body already set; choose one of body/bytes/stream/sse.');
    }

    _streamData = data;
    _isStream = true;
    _flushEachChunk = flushEachChunk;

    headers['Content-Type'] = contentType;
    headers['Cache-Control'] = 'no-cache';

    if (statusCode != null) {
      setStatus(statusCode);
    }
  }

  /// Sends Server-Sent Events (SSE) to the client.
  ///
  /// SSE enables real-time server-to-client streaming over HTTP.
  ///
  /// ## Parameters
  ///
  /// - [handler]: Async function that receives an [SSESink] for sending events
  /// - [keepAlive]: Optional interval for automatic keep-alive pings
  ///
  /// ## Example
  ///
  /// ```dart
  /// app.get('/events', (req, res) async {
  ///   res.sse((sink) async {
  ///     sink.sendEvent('Hello!');
  ///     sink.sendEvent('Update', event: 'notification');
  ///
  ///     // Stream updates
  ///     for (var i = 0; i < 10; i++) {
  ///       await Future.delayed(Duration(seconds: 1));
  ///       sink.sendEvent('Event $i');
  ///     }
  ///
  ///     sink.close();
  ///   });
  /// });
  /// ```
  Future<void> sse(
    Future<void> Function(SSESink sink) handler, {
    Duration? keepAlive,
  }) async {
    // Prevent both stream and SSE being set
    if (_isStream) {
      throw StateError('Cannot use sse() after stream() has been called');
    }
    if (_isSse) {
      throw StateError('SSE already configured for this response.');
    }
    if (body != null || isBinary) {
      throw StateError(
          'Response body already set; choose one of body/bytes/stream/sse.');
    }

    // Store SSE handler and mark response as SSE
    _sseHandler = handler;
    _sseKeepAlive = keepAlive;
    _isSse = true;

    // Set SSE headers with proper charset
    headers['Content-Type'] = 'text/event-stream; charset=utf-8';
    headers['Cache-Control'] = 'no-cache';
    headers['Connection'] = 'keep-alive';
    headers['X-Accel-Buffering'] = 'no'; // Disable nginx buffering
  }

  /// Whether this response is configured for SSE.
  bool get isSse => _isSse;

  /// Flushes the accumulated headers/cookies into the provided [HttpResponse]
  /// and closes the sink. Subsequent invocations are ignored.
  Future<void> send(HttpResponse httpResponse) async {
    if (isSent) return;
    _writeCookies(httpResponse);
    _isSent = true;

    httpResponse.statusCode = statusCode;

    headers.forEach((name, value) {
      httpResponse.headers.set(name, value);
    });

    // Disable buffering and enable chunked transfer for streaming responses
    if (_isStream || _isSse) {
      httpResponse.bufferOutput = false;
      httpResponse.headers.chunkedTransferEncoding = true;
    }

    // Handle generic streaming
    if (_isStream && _streamData != null) {
      try {
        if (_flushEachChunk) {
          // Flush after each chunk for real-time streaming
          await for (final chunk in _streamData!) {
            httpResponse.add(chunk);
            await httpResponse.flush();
          }
        } else {
          // Use addStream for better performance
          await httpResponse.addStream(_streamData!);
        }
      } finally {
        // Always close the response
        try {
          await httpResponse.close();
        } catch (_) {
          // Ignore close errors to preserve original streaming error.
        }
      }
      return;
    }

    // Handle SSE responses
    if (_isSse && _sseHandler != null) {
      final sink = SSESink(httpResponse);

      // Start keep-alive if configured
      if (_sseKeepAlive != null) {
        sink.startKeepAlive(_sseKeepAlive!);
      }

      try {
        await _sseHandler!(sink);
      } catch (e) {
        // Error in SSE handler, close gracefully
        if (!sink.isClosed) {
          await sink.close();
        }
        rethrow;
      } finally {
        // Ensure connection is closed
        if (!sink.isClosed) {
          await sink.close();
        }
      }
      return;
    }

    // Normal response handling
    if (isBinary) {
      httpResponse.add(body as Uint8List);
    } else if (body != null) {
      httpResponse.write(body);
    }

    await httpResponse.close();
  }

  void setHeader(String name, String value) {
    headers[name] = value;
  }

  void setStatus(int code) {
    statusCode = code;
  }

  void _writeCookies(HttpResponse httpResponse) {
    if (_cookies.isEmpty) {
      return;
    }

    for (final cookie in _cookies) {
      httpResponse.cookies.add(cookie);
    }
  }

  void _replaceCookie(Cookie cookie) {
    _cookies.removeWhere((existing) {
      final sameName = existing.name == cookie.name;
      final existingPath = existing.path ?? '/';
      final newPath = cookie.path ?? '/';
      return sameName && existingPath == newPath;
    });
    _cookies.add(cookie);
  }
}
