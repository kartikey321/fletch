# Fletch Dev Tools

Development tools for the [Fletch](https://pub.dev/packages/fletch) framework - providing hot reload, hot restart, and CLI tools for a Flutter-like development experience with backend Dart applications.

## Features

- 🔥 **Hot Reload** - Update code instantly without restarting (39-151ms)
- 🔄 **Hot Restart** - Fast process restart when needed (< 1 second)
- 🧠 **Smart Detection** - Automatically decides reload vs restart
- 📁 **File Watching** - Monitors your code for changes
- 🛡️ **Fallback Logic** - Gracefully handles reload failures
- 🎯 **Zero Configuration** - Works out of the box

## Installation

### Global Installation (Recommended)

```bash
dart pub global activate fletch_dev_tools
```

### Project Installation

```yaml
dev_dependencies:
  fletch_dev_tools: ^1.0.0
```

## Usage

### Command Line

```bash
# Basic usage
fletch dev --entry bin/main.dart

# Custom port
fletch dev --entry bin/main.dart --port 8080

# Watch multiple directories
fletch dev --entry bin/main.dart --watch lib,routes,controllers

# Verbose incremental compiler logs
fletch dev --entry bin/main.dart --verbose-compiler

# Tune compiler recovery policy
fletch dev --entry bin/main.dart \
  --compiler-max-recovery-attempts 2 \
  --compiler-max-diagnostics 120 \
  --compiler-recovery-backoff-ms 250

# Show help
fletch dev --help
```

### Example Output

```
╔════════════════════════════════════════╗
║   Fletch Development Server            ║
╚════════════════════════════════════════╝

📂 Watching: lib
🚀 Entry: bin/main.dart
🔌 Port: 3000

🚀 Starting server: bin/main.dart
📡 VM service: http://127.0.0.1:54931/abc123=/
✅ Server started
🔥 Hot reload enabled
👀 Watching: lib

📝 File changed: lib/routes/users.dart
🔄 Hot reloading...
✅ Hot reload successful (39ms)
```

## How It Works

### Hot Reload (Fast)

For most code changes in `lib/`:

```dart
// Edit a function
void getUserById(Request req, Response res) {
  res.json({'id': 1, 'name': 'Updated!'}); // Change this
}
```

**Result:** Hot reload in ~39ms, state preserved ⚡

### Hot Restart (Safe)

For structural changes:

```dart
// Edit main.dart or pubspec.yaml
```

**Result:** Hot restart in ~500ms, process restarted 🔄

### Smart Detection

The dev server automatically decides:

- **Hot Reload** → Changes in `lib/*.dart`
- **Hot Restart** → Changes in `main.dart`, `pubspec.yaml`, `*.g.dart`

## Performance

| Change Type | Method | Time | State Preserved |
|-------------|--------|------|-----------------|
| Function body | Hot Reload | **39-151ms** | ✅ Yes |
| Main file | Hot Restart | **~500ms** | ❌ No |

**Hot reload is 3-13x faster than hot restart!**

## Architecture

```
┌─────────────────────────────────────────┐
│      Fletch Dev Tools                   │
├─────────────────────────────────────────┤
│                                         │
│  File Watcher → Change Analyzer        │
│                      ↓                  │
│          ┌──────────┴──────────┐       │
│          ↓                     ↓       │
│    Hot Reload            Hot Restart   │
│   (VM Service)           (Process)     │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │   Your Fletch App (Child Process) │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Requirements

- Dart SDK 3.6.0 or higher
- Fletch 2.0.2 or higher

## Comparison with package:hotreloader

| Feature | fletch_dev_tools | package:hotreloader |
|---------|------------------|---------------------|
| Hot Reload | ✅ Yes | ✅ Yes |
| Hot Restart | ✅ Yes | ❌ No |
| Smart Detection | ✅ Automatic | ⚠️ Manual |
| CLI Tool | ✅ Yes | ❌ No |
| Separation | ✅ Separate process | ❌ In-process |

## Contributing

Contributions are welcome! Please read our [contributing guidelines](../../CONTRIBUTING.md).

## License

MIT License - see [LICENSE](../../LICENSE) for details.

## Links

- [Fletch Framework](https://pub.dev/packages/fletch)
- [Documentation](https://docs.fletch.mahawarkartikey.in)
- [GitHub Repository](https://github.com/kartikey321/fletch)
- [Issue Tracker](https://github.com/kartikey321/fletch/issues)
