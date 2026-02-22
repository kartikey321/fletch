# Routing

Fletch uses a fast radix-tree router to match incoming requests to handlers.

## Basic Routes

Define routes for different HTTP methods:

```dart
final app = Fletch();

app.get('/users', (req, res) {
  res.json({'users': []});
});

app.post('/users', (req, res) async {
  final body = await req.body;
  res.status(201).json(body);
});

app.put('/users/:id', (req, res) {
  res.json({'updated': req.params['id']});
});

app.delete('/users/:id', (req, res) {
  res.status(204).send();
});
```

> **Note**: Route methods (`get`, `post`, etc.) return `void`, so they cannot be chained.

## Path Parameters

Capture dynamic segments from the URL:

```dart
app.get('/users/:userId/posts/:postId', (req, res) {
  final userId = req.params['userId'];
  final postId = req.params['postId'];
  
  res.json({
    'userId': userId,
    'postId': postId,
  });
});
```

Access via: `/users/123/posts/456`

## Query Parameters

Access query string parameters using `req.query`:

```dart
app.get('/search', (req, res) {
  // /search?q=dart&page=2
  final query = req.query['q'];
  final page = int.tryParse(req.query['page'] ?? '1') ?? 1;
  
  res.json({
    'query': query,
    'page': page,
  });
});
```

## Wildcard Routes

Match multiple path segments using `*`:

```dart
app.get('/files/*', (req, res) {
  // Access the matched wildcard value via regular params or specialized logic
  // Typically, wildcards match everything remaining in the path
  res.text('Matched file request');
});
```

Access `/files/documents/report.pdf` triggers this handler.

## Controllers

For larger applications, organize routes using the **Controller** class.

1. Create a controller by extending `Controller`.
2. Override `registerRoutes` to define endpoints.
3. Mount it using `useController`.

```dart
import 'package:fletch/fletch.dart';

class UserController extends Controller {
  @override
  void registerRoutes(ControllerOptions options) {
    // GET /users/
    options.get('/', getAll);
    
    // GET /users/:id
    options.get('/:id', getById);
    
    // POST /users/
    options.post('/', create);
  }

  void getAll(Request req, Response res) {
    res.json(['user1', 'user2']);
  }

  void getById(Request req, Response res) {
    res.json({'id': req.params['id']});
  }

  Future<void> create(Request req, Response res) async {
    final body = await req.body;
    res.status(201).json(body);
  }
}

void main() {
  final app = Fletch();
  
  // Mounts all controller routes under /users
  app.useController('/users', UserController());
  
  app.listen(3000);
}
```

This pattern keeps your `main()` function clean and your route logic modular.

## Route Groups

You can also group routes using `base_container` organization or by simply mounting `IsolatedContainer`s for larger features.

See [Isolated Containers](/advanced/isolated-containers) for advanced grouping.

## Route Order

Routes are matched based on the radix tree structure. Specific static paths generally take precedence, but parameterized routes are matched when no static path exists.

```dart
// Static path
app.get('/users/me', (req, res) { ... });

// Parameterized path
app.get('/users/:id', (req, res) { ... });
```

Requesting `/users/me` will match the first handler. Requesting `/users/123` will match the second.

## All Methods

Handle any HTTP method for a path:

```dart
app.all('/api/*', (req, res, next) async {
  print('API called: ${req.method} ${req.uri.path}');
  await next();
});
```

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/getting-started/quick-start" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🚀 Quick Start</span>
  </a>
  <a href="/core-concepts/middleware" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🧩 Middleware</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
