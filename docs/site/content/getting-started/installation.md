# Installation

Get started with Fletch in minutes.

## Requirements

- **Dart SDK**: 3.6.0 or later
- **Platform**: Windows, macOS, Linux

## Install via Pub

```bash
dart pub add fletch
```

This adds the latest version to your `pubspec.yaml` and runs `dart pub get` automatically.

## Create Your First Server

Create `bin/server.dart`:

```dart
import 'package:fletch/fletch.dart';

void main() async {
  final app = Fletch();
  
  app.get('/', (req, res) {
    res.text('Hello from fletch!');
  });
  
  await app.listen(3000);
  print('🚀 Server running on http://localhost:3000');
}
```

## Run Your Server

```bash
dart run bin/server.dart
```

Visit [http://localhost:3000](http://localhost:3000) to see your server in action!

## Verify Installation

Test that everything works:

```bash
curl http://localhost:3000
# Output: Hello from fletch!
```

## Optional Dependencies

### For MongoDB Support
```yaml
dependencies:
  mongo_dart: ^0.9.0
```

### For Testing
```yaml
dev_dependencies:
  test: ^1.24.0
  http: ^1.1.0
```

## Project Structure

A typical Fletch project:

```
my_api/
├── bin/
│   └── server.dart          # Entry point
├── lib/
│   ├── controllers/         # Route controllers
│   ├── models/              # Data models
│   ├── services/            # Business logic
│   └── middleware/          # Custom middleware
├── test/
│   └── server_test.dart
└── pubspec.yaml
```

<div style="display:flex;justify-content:space-between;gap:1rem;align-items:center;margin:2rem 0;">
  <a href="/" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span aria-hidden="true">‹</span>
    <span>🏁 Overview</span>
  </a>
  <a href="/getting-started/quick-start" style="display:flex;align-items:center;gap:0.4rem;text-decoration:none;color:inherit;">
    <span>🚀 Quick Start</span>
    <span aria-hidden="true">›</span>
  </a>
</div>

<Info>
**Pro Tip**: Use `dart run --observe` to enable debugging with Dart DevTools!
</Info>
