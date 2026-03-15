# CORS (Cross-Origin Resource Sharing)

Configure Cross-Origin Resource Sharing to allow your API to be accessed from different domains.

## Quick Start

Enable CORS for all origins (development only):

```dart
final app = Fletch();

app.use(app.cors());

app.get('/api/data', (req, res) {
  res.json({'message': 'CORS enabled!'});
});
```

## Production Configuration

Restrict origins in production:

```dart
app.use(app.cors(
  allowedOrigins: [
    'https://myapp.com',
    'https://www.myapp.com',
  ],
  allowedMethods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true,
));
```

## Configuration Options

### Allow Specific Origins

```dart
app.use(app.cors(
  allowedOrigins: ['https://example.com'],
));
```

### Allow All Origins (Development)

```dart
app.use(app.cors(
  allowedOrigins: ['*'], // Allow all
));
```

### Allow Methods

```dart
app.use(app.cors(
  allowedMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
));
```

### Allow Headers

```dart
app.use(app.cors(
  allowedHeaders: [
    'Content-Type',
    'Authorization',
    'X-Custom-Header',
  ],
));
```

### Credentials

Allow cookies and authentication:

```dart
app.use(app.cors(
  credentials: true,
  allowedOrigins: ['https://myapp.com'], // Required when credentials: true
));
```

## Preflight Requests

CORS automatically handles OPTIONS preflight requests:

```
Client                    Server
  |                         |
  |-- OPTIONS /api/data --> |
  |                         |
  |<-- 204 No Content ----- | (with CORS headers)
  |                         |
  |-- POST /api/data -----> |
  |<-- 200 OK ------------- |
```

## Common Use Cases

### API for Web App

```dart
app.use(app.cors(
  allowedOrigins: [
    'https://app.example.com',
    'https://dashboard.example.com',
  ],
  allowedMethods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true,
));
```

### Public Read-Only API

```dart
app.use(app.cors(
  allowedOrigins: ['*'],
  allowedMethods: ['GET'],
  allowedHeaders: ['Content-Type'],
));
```

### Development with localhost

```dart
app.use(app.cors(
  allowedOrigins: [
    'http://localhost:3000',
    'http://localhost:5173', // Vite
    'http://localhost:8080',
  ],
));
```

## Custom CORS Middleware

For advanced scenarios, create custom CORS middleware:

```dart
Future<void> customCors(Request req, Response res, NextFunction next) async {
  final origin = req.headers['origin'];
  
  // Dynamic origin check
  if (origin != null && origin.endsWith('.example.com')) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
  }
  
  // Handle preflight
  if (req.method == 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE');
    return res.status(204).send();
  }
  
  await next();
}

app.use(customCors);
```

## Security Best Practices

### Never use `*` with credentials

❌ **Insecure:**
```dart
app.use(app.cors(
  allowedOrigins: ['*'],
  credentials: true, // SECURITY RISK!
));
```

✅ **Secure:**
```dart
app.use(app.cors(
  allowedOrigins: ['https://myapp.com'],
  credentials: true,
));
```

### Validate origins carefully

```dart
final allowedOrigins = [
  'https://myapp.com',
  'https://www.myapp.com',
  // Add staging/dev as needed
];

app.use(app.cors(
  allowedOrigins: allowedOrigins,
));
```

### Limit methods and headers

Only allow what you need:

```dart
app.use(app.cors(
  allowedMethods: ['GET', 'POST'], // Not PUT/DELETE if unused
  allowedHeaders: ['Content-Type'], // Minimal headers
));
```

## Testing CORS

### With curl

```bash
curl -H "Origin: https://example.com" \
     -H "Access-Control-Request-Method: POST" \
     -H "Access-Control-Request-Headers: Content-Type" \
     -X OPTIONS \
     http://localhost:3000/api/data
```

### With JavaScript

```javascript
fetch('http://localhost:3000/api/data', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
  },
  credentials: 'include', // For cookies
  body: JSON.stringify({data: 'test'}),
});
```

## Common Errors

### "No 'Access-Control-Allow-Origin' header"

**Cause:** CORS not enabled or origin not allowed

**Solution:** Add CORS middleware:
```dart
app.use(app.cors(
  allowedOrigins: ['https://yourapp.com'],
));
```

### "Credential is not supported if wildcard"

**Cause:** Using `*` with `credentials: true`

**Solution:** Specify exact origins:
```dart
app.use(app.cors(
  allowedOrigins: ['https://yourapp.com'], // Not '*'
  credentials: true,
));
```

## Rate Limiting

Protect your API from abuse by adding rate limiting middleware:

```dart
app.use(app.rateLimiter(
  maxRequests: 100,
  window: Duration(minutes: 1),
));
```

### Rate limiting behind a reverse proxy

The default key is the TCP-layer remote IP. Behind nginx, AWS ALB, or Cloudflare, every request arrives from the proxy's IP — collapsing all real clients into a single bucket and making rate limiting useless.

Supply a `keyGenerator` that reads the forwarded IP instead:

```dart
app.use(app.rateLimiter(
  maxRequests: 100,
  window: Duration(minutes: 1),
  keyGenerator: (req) {
    // Only trust this header if your proxy strips any
    // client-supplied X-Forwarded-For before adding its own.
    final forwarded = req.headers.value('x-forwarded-for');
    return forwarded?.split(',').first.trim()
        ?? req.httpRequest.connectionInfo?.remoteAddress.address
        ?? 'unknown';
  },
));
```

> **Warning:** Never trust `X-Forwarded-For` unless your proxy is configured to strip the header from incoming client requests first. An attacker can spoof any IP by setting the header themselves, bypassing rate limits entirely.

You can also key by authenticated user to rate-limit per account rather than per IP:

```dart
app.use(app.rateLimiter(
  maxRequests: 1000,
  window: Duration(minutes: 1),
  keyGenerator: (req) => req.session['userId'] as String? ?? 'anonymous',
));
```

## Next Steps

- [Sessions](/core-concepts/sessions) - Manage authenticated users
- [Best Practices](/security/best-practices) - Security guidelines
