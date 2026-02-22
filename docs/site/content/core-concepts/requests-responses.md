# Requests & Responses

Fletch provides rich `Request` and `Response` objects to handle HTTP interactions.

## The Request Object

The `Request` object (`req`) represents the HTTP request and provides access to the request body, query string, parameters, headers, and more.

### Request Body

Fletch automatically parses the request body based on the `Content-Type` header.

```dart
app.post('/api/data', (req, res) async {
  // Parsing is async because the body stream is read on demand
  final body = await req.body;
  
  if (body is Map) {
    // JSON or Form URL Encoded
    print(body['name']);
  } else if (body is String) {
    // Plain text
    print(body);
  }
});
```

### Path & Query Parameters

```dart
// Route: /users/:id
app.get('/users/:id', (req, res) {
  // Path params
  final id = req.params['id'];
  
  // Query params: /users/123?details=true
  final details = req.query['details'] == 'true';
});
```

### File Uploads (Multipart)

Fletch has built-in support for `multipart/form-data`. Use `req.formData` to access both fields and files.

```dart
app.post('/upload', (req, res) async {
  final formData = await req.formData;
  
  // Access regular fields
  final title = formData['title'];
  
  // Access files (returns List<MultipartFile>)
  final files = formData['document'] as List<MultipartFile>?;
  
  if (files != null) {
    final file = files.first;
    print('Filename: ${file.filename}');
    print('Size: ${file.length} bytes');
  }
});
```

### Dependency Injection

Access the DI container scoped to the request:

```dart
app.get('/users', (req, res) {
  // Retrieve a registered service
  final userService = req.container.get<UserService>();
  res.json(userService.getAll());
});
```

---

## The Response Object

The `Response` object (`res`) provides helper methods to send data to the client.

### Sending Data

```dart
// JSON
res.json({'message': 'Hello'});

// Plain Text
res.text('Hello World');

// HTML
res.html('<h1>Hello</h1>');

// XML
res.xml('<root>Hello</root>');

// Status Code only
res.status(204).send();
```

### Cookies

Manage cookies with `cookie()` and `clearCookie()`.

```dart
// Set a cookie
res.cookie('token', 'abc-123', 
  httpOnly: true,
  secure: true,
  maxAge: 3600, // 1 hour
);

// Clear a cookie
res.clearCookie('token');
```

### File Downloads

Send files from disk. Content-Type is automatically detected.

```dart
app.get('/download', (req, res) async {
  final file = File('report.pdf');
  await res.file(file);
});
```

### Redirects

```dart
app.get('/old-page', (req, res) {
  res.redirect('/new-page');
});
```

### Streaming responses

Stream data to the client chunk-by-chunk.

```dart
app.get('/stream', (req, res) async {
  final stream = File('large-video.mp4').openRead();
  
  // flushEachChunk: true allows real-time streaming
  await res.stream(stream, 
    contentType: 'video/mp4',
    flushEachChunk: true
  );
});
```

### Server-Sent Events (SSE)

Push real-time updates to the client using SSE.

```dart
app.get('/events', (req, res) async {
  res.sse((sink) async {
    // Send an event
    sink.sendEvent('Connected!');
    
    // Send named event with ID
    sink.sendEvent(
      jsonEncode({'update': 'available'}), 
      event: 'system_update',
      id: 'evt_1'
    );
    
    // Maintain connection
    while (true) {
      await Future.delayed(Duration(seconds: 1));
      sink.sendEvent('ping');
    }
  });
});
```

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/getting-started/configuration" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>⚙️ Configuration</span>
  </a>
  <a href="/core-concepts/routing" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🧭 Routing</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
