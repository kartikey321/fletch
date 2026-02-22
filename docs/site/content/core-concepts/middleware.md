# Middleware

Middleware functions are the building blocks of Fletch applications. They process requests, modify responses, and control the flow of execution.

## What is Middleware?

Middleware is a function that has access to the request object (`req`), response object (`res`), and the next middleware function (`next`).

```dart
Future<void> myMiddleware(Request req, Response res, NextFunction next) async {
  // Do something before the route handler
  print('Request received');
  
  // Pass control to the next middleware
  await next();
  
  // Do something after the route handler
  print('Response sent');
}
```

## Using Middleware

### Global Middleware

Applies to all routes:

```dart
final app = Fletch();

// Logging middleware
app.use((req, res, next) async {
  print('[${DateTime.now()}] ${req.method} ${req.uri.path}');
  await next();
});

// Your routes
app.get('/', (req, res) => res.text('Hello!'));
```

### Route-Specific Middleware

Apply to specific routes:

```dart
Future<void> authMiddleware(Request req, Response res, NextFunction next) async {
  final token = req.headers['authorization'];
  
  if (token == null) {
    return res.status(401).json({'error': 'Unauthorized'});
  }
  
  // Verify token...
  await next();
}

app.get('/protected', authMiddleware, (req, res) {
  res.json({'message': 'Secret data'});
});
```

## Built-in Middleware

### CORS

Enable Cross-Origin Resource Sharing:

```dart
app.use(app.cors(
  allowedOrigins: ['https://example.com'],
  allowedMethods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true,
));
```

### Rate Limiting

Protect against abuse:

```dart
app.use(app.rateLimit(
  maxRequests: 100,
  windowMs: 60000, // 1 minute
));
```

## Middleware Patterns

### Authentication

```dart
Future<void> requireAuth(Request req, Response res, NextFunction next) async {
  if (!req.session.containsKey('userId')) {
    return res.status(401).json({'error': 'Please log in'});
  }
  await next();
}

app.get('/profile', requireAuth, (req, res) {
  final userId = req.session['userId'];
  res.json({'userId': userId});
});
```

### Request Validation

```dart
Future<void> validateUser(Request req, Response res, NextFunction next) async {
  final body = await req.body;
  
  if (body['email'] == null || body['password'] == null) {
    return res.status(400).json({
      'error': 'Email and password required'
    });
  }
  
  await next();
}

app.post('/signup', validateUser, (req, res) async {
  final body = await req.body;
  // Create user...
});
```

### Error Handler Signature

Custom error handlers must match this signature:

```dart
typedef ErrorHandler = FutureOr<void> Function(
    dynamic error, Request request, Response response);
```

### The HttpError Class

Fletch provides a built-in `HttpError` class for standard HTTP exceptions. Throwing these will automatically result in the correct status code and JSON response.

**Available Errors:**

- `HttpError(statusCode, message, [data])`: Generic error.
- `ValidationError(message, [data])`: 400 Bad Request.
- `UnauthorizedError(message, [data])`: 401 Unauthorized.
- `NotFoundError(message, [data])`: 404 Not Found.
- `RouteConflictError(message, [data])`: 409 Conflict.

**Example:**

```dart
app.get('/user/:id', (req, res) {
  final user = findUser(req.params['id']);
  
  if (user == null) {
    throw NotFoundError('User not found');
  }
  
  if (!user.isActive) {
    throw UnauthorizedError('Account disabled');
  }
  
  res.json(user);
});
```

### Custom Error Handler

Install a global error handler to customize responses:

```dart
app.setErrorHandler((error, req, res) async {
  if (error is HttpError) {
    res.status(error.statusCode).json({
      'error': error.message,
      'details': error.data
    });
  } else {
    // Log unexpected errors
    print('Unexpected error: $error');
    res.status(500).json({'error': 'Internal Server Error'});
  }
});
```

### Request Timing

```dart
app.use((req, res, next) async {
  final start = DateTime.now();
  
  await next();
  
  final duration = DateTime.now().difference(start);
  print('${req.method} ${req.uri.path} - ${duration.inMilliseconds}ms');
});
```

## Middleware Order

Middleware executes in the order it's defined:

```dart
// 1. Logging
app.use((req, res, next) async {
  print('1: Before');
  await next();
  print('1: After');
});

// 2. Auth check
app.use((req, res, next) async {
  print('2: Before');
  await next();
  print('2: After');
});

// 3. Route handler
app.get('/', (req, res) {
  print('3: Handler');
  res.text('Hello!');
});
```

Output:
```
1: Before
2: Before
3: Handler
2: After  
1: After
```

## Stopping the Chain

Don't call `next()` to stop:

```dart
app.use((req, res, next) async {
  if (req.headers['api-key'] != 'secret') {
    return res.status(403).json({'error': 'Forbidden'});
    // next() NOT called - stops here
  }
  await next();
});
```

## Modifying Request/Response

Middleware can modify the request/response objects:

```dart
app.use((req, res, next) async {
  // Add custom data to request
  req.session['timestamp'] = DateTime.now().toIso8601String();
  
  // Add custom headers to response
  res.setHeader('X-Powered-By', 'fletch');
  
  await next();
});
```

## Third-Party Middleware

Create reusable middleware packages:

```dart
// my_logger_middleware.dart
Future<void> loggerMiddleware({
  bool showTimestamp = true,
}) {
  return (Request req, Response res, NextFunction next) async {
    final time = showTimestamp ? '[${DateTime.now()}] ' : '';
    print('$time${req.method} ${req.uri.path}');
    await next();
  };
}

// Usage
app.use(loggerMiddleware(showTimestamp: true));
```

## Best Practices

1. **Keep middleware focused** - Each middleware should do one thing well
2. **Always call next()** - Unless you're terminating the request
3. **Error handling** - Wrap route handlers in try-catch middleware
4. **Order matters** - Put logging first, error handling last
5. **Async/await** - Always use async and await next()

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/core-concepts/routing" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🧭 Routing</span>
  </a>
  <a href="/core-concepts/sessions" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🔐 Sessions</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
