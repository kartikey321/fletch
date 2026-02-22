# Error Handling

Fletch provides a robust error handling system that simplifies returning standard HTTP error responses and supports custom global error handling.

## The HttpError Class

The core of Fletch's error handling is the `HttpError` class. When you throw an `HttpError` (or a subclass) from any route or middleware, Fletch automatically catches it and sends a structured JSON response with the appropriate status code.

### Built-in Error Types

Fletch includes several pre-defined error classes for common scenarios:

- **`HttpError(statusCode, message, [data])`**: Generic error.
- **`ValidationError(message, [data])`**: 400 Bad Request.
- **`UnauthorizedError(message, [data])`**: 401 Unauthorized.
- **`NotFoundError(message, [data])`**: 404 Not Found.
- **`RouteConflictError(message, [data])`**: 409 Conflict.

### Usage Example

Throwing errors in your routes allows execution to stop immediately and lets the framework handle the response.

```dart
app.get('/users/:id', (req, res) {
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

The client will receive a 404 response body like:

```json
{
  "error": "User not found",
  "data": null
}
```

## Global Error Handler

You can define a custom global error handler to control the exact format of your error responses or to integrate with logging services (like Sentry or Datadog).

### Handler Signature

```dart
typedef ErrorHandler = FutureOr<void> Function(
    dynamic error, Request request, Response response);
```

### Configuration

Pass your custom handler to `app.setErrorHandler()`:

```dart
void main() {
  final app = Fletch();

  app.setErrorHandler((error, req, res) async {
    // 1. Log the error
    print('Error: $error');

    // 2. Handle known HttpErrors
    if (error is HttpError) {
      res.status(error.statusCode).json({
        'success': false,
        'error': {
          'code': error.statusCode,
          'message': error.message,
          'details': error.data,
        }
      });
      return;
    }

    // 3. Handle unexpected errors (hide details in production)
    res.status(500).json({
      'success': false,
      'error': {
        'code': 500,
        'message': 'Internal Server Error',
      }
    });
  });

  app.listen(3000);
}
```

## Validation Errors

The `ValidationError` class is perfect for returning detailed form validation issues.

```dart
app.post('/register', (req, res) async {
  final body = await req.body;
  
  if (body['email'] == null) {
    throw ValidationError('Invalid input', {'email': 'Email is required'});
  }
});
```

Response (400 Bad Request):
```json
{
  "error": "Invalid input",
  "data": {
    "email": "Email is required"
  }
}
```

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/core-concepts/middleware" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🧩 Middleware</span>
  </a>
  <a href="/core-concepts/sessions" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🔐 Sessions</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
