# Isolated Containers

Isolated containers allow you to modularize your application by creating self-contained services with their own routing, middleware, and dependency injection scopes.

## Overview

`IsolatedContainer` provides:
- **Prefix-based routing** - Mount under specific path prefixes
- **Isolated dependencies** - Separate DI container per service
- **Middleware isolation** - Independent middleware pipeline  
- **Shared sessions** - Coordinates with parent app
- **Modular architecture** - Organize large apps into services

## Basic Usage

Create and mount an isolated container:

```dart
import 'package:fletch/fletch.dart';

void main() async {
  final app = Fletch();
  
  // Create isolated container for admin routes
  final admin = IsolatedContainer(prefix: '/admin');
  
  admin.get('/', (req, res) {
    res.text('Admin Dashboard');
  });
  
  admin.get('/users', (req, res) {
    res.json({'users': []});
  });
  
  // Mount the container
  admin.mount(app);
  
  // Main app routes
  app.get('/', (req, res) {
    res.text('Homepage');
  });
  
  await app.listen(3000);
}
```

Access routes:
- `/` → Homepage (main app)
- `/admin` → Admin Dashboard (isolated)
- `/admin/users` → Users list (isolated)

## Use Cases

### 1. API Versioning

Separate API versions with different dependencies:

```dart
void main() async {
  final app = Fletch();
  
  // API v1
  final v1 = IsolatedContainer(prefix: '/api/v1');
  v1.container.registerSingleton(UserServiceV1());
  
  v1.get('/users', (req, res) {
    final service = req.container<UserServiceV1>();
    res.json(service.getAll());
  });
  
  v1.mount(app);
  
  // API v2 with new service implementation
  final v2 = IsolatedContainer(prefix: '/api/v2');
  v2.container.registerSingleton(UserServiceV2());
  
  v2.get('/users', (req, res) {
    final service = req.container<UserServiceV2>();
    res.json(service.getAllPaginated());
  });
  
  v2.mount(app);
  
  await app.listen(3000);
}
```

### 2. Microservices Architecture

Organize app into logical services:

```dart
void main() async {
  final app = Fletch();
  
  // Auth service
  final auth = IsolatedContainer(prefix: '/auth');
  auth.post('/login', loginHandler);
  auth.post('/logout', logoutHandler);
  auth.mount(app);
  
  // User service
  final users =  IsolatedContainer(prefix: '/users');
  users.get('/', getAllUsers);
  users.get('/:id', getUser);
  users.mount(app);
  
  // Payment service
  final payments = IsolatedContainer(prefix: '/payments');
  payments.post('/charge', chargeHandler);
  payments.get('/history', historyHandler);
  payments.mount(app);
  
  await app.listen(3000);
}
```

### 3. Multi-Tenant Applications

Isolate tenant-specific logic:

```dart
void main() async {
  final app = Fletch();
  
  // Tenant A
  final tenantA = IsolatedContainer(prefix: '/tenant-a');
  tenantA.container.registerSingleton(DatabaseA());
  tenantA.get('/data', (req, res) {
    final db = req.container.get<DatabaseA>();
    res.json(db.query());
  });
  tenantA.mount(app);
  
  // Tenant B
  final tenantB = IsolatedContainer(prefix: '/tenant-b');
  tenantB.container.registerSingleton(DatabaseB());
  tenantB.get('/data', (req, res) {
    final db = req.container.get<DatabaseB>();
    res.json(db.query());
  });
  tenantB.mount(app);
  
  await app.listen(3000);
}
```

## Dependency Injection

Each container has its own DI scope:

```dart
class AdminService {
  List<String> getAdmins() => ['admin1', 'admin2'];
}

class UserService {
  List<String> getUsers() => ['user1', 'user2'];
}

void main() async {
  final app = Fletch();
  app.container.registerSingleton(UserService());
  
  final admin = IsolatedContainer(prefix: '/admin');
  admin.container.registerSingleton(AdminService());
  
  admin.get('/list', (req, res) {
    // Access isolated container's service
    final adminService = req.container<AdminService>();
    
    // Can also access parent container if needed
    // But isolated container takes precedence
    res.json({'admins': adminService.getAdmins()});
  });
  
  admin.mount(app);
  
  await app.listen(3000);
}
```

## Middleware Isolation

Container middleware only applies to its routes:

```dart
void main() async {
  final app = Fletch();
  
  // Global middleware
  app.use((req, res, next) async {
    print('Global: ${req.uri.path}');
    await next();
  });
  
  // Admin container with auth middleware
  final admin = IsolatedContainer(prefix: '/admin');
  
  admin.use((req, res, next) async {
    // This only runs for /admin/* routes
    if (req.session['role'] != 'admin') {
      return res.status(403).json({'error': 'Admin only'});
    }
    await next();
  });
  
  admin.get('/dashboard', (req, res) {
    res.text('Admin Dashboard');
  });
  
  admin.mount(app);
  
  await app.listen(3000);
}
```

## Session Sharing

Sessions are shared between parent and isolated containers:

```dart
void main() async {
  final app = Fletch(
    sessionSecret: 'secret',
  );
  
  app.post('/login', (req, res) async {
    req.session['userId'] = '123';
    req.session['role'] = 'admin';
    res.json({'success': true});
  });
  
  final admin = IsolatedContainer(prefix: '/admin');
  
  admin.get('/profile', (req, res) {
    // Access session from parent request
    final userId = req.session['userId'];
    final role = req.session['role'];
    
    res.json({
      'userId': userId,
      'role': role,
    });
  });
  
  admin.mount(app);
  
  await app.listen(3000);
}
```

## Path Resolution

Paths are resolved relative to the container prefix:

```dart
final api = IsolatedContainer(prefix: '/api');

// These are equivalent:
api.get('/users', handler);    // Mounted at /api/users
api.get('users', handler);     // Also mounted at /api/users

// Root of container
api.get('/', handler);         // Mounted at /api
```

## Standalone Mode

Run container as independent service:

```dart
void main() async {
  final service = IsolatedContainer(prefix: '');
  
  service.get('/', (req, res) {
    res.text('Standalone Service');
  });
  
  service.get('/health', (req, res) {
    res.json({'status': 'ok'});
  });
  
  // Listen on its own port
  await service.listen(8080);
  print('Service running on port 8080');
}
```

## Advanced Patterns

### Plugin System

Create reusable service modules:

```dart
class BlogPlugin {
  IsolatedContainer create() {
    final blog = IsolatedContainer(prefix: '/blog');
    
    blog.get('/', getAllPosts);
    blog.get('/:id', getPost);
    blog.post('/', createPost);
    
    blog.container.registerSingleton(BlogService());
    
    return blog;
  }
}

void main() async {
  final app = Fletch();
  
  // Mount blog plugin
  final blog = BlogPlugin().create();
  blog.mount(app);
  
  await app.listen(3000);
}
```

### Nested Containers

Mount containers within containers:

```dart
void main() async {
  final app = Fletch();
  
  final api = IsolatedContainer(prefix: '/api');
  
  final v1 = IsolatedContainer(prefix: '/v1');
  v1.get('/users', handler);
  v1.mount(api);  // Mounted at /api/v1/users
  
  api.mount(app);
  
  await app.listen(3000);
}
```

## Best Practices

1. **Use meaningful prefixes** - `/api/v1`, `/admin`, `/tenant-123`
2. **Isolate dependencies** - Register services specific to each container
3. **Share global state** - Use parent container for shared services
4. **Document boundaries** - Clearly define which routes belong where
5. **Test isolation** - Unit test containers independently

## Performance

Isolated containers have minimal overhead:
- Routes matched by parent router first
- Delegation only when prefix matches
- Shared response object (no duplication)
- Same performance as regular routes

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/examples/todo-api" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🗒️ TODO API</span>
  </a>
  <a href="/about" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>ℹ️ About</span>
    <span aria-hidden="true">›</span>
  </a>
</div>
