# Changelog

## 1.0.0 - 2026-01-14

### Initial Release

- ✨ Hot reload support via Dart VM Service (39-151ms)
- ✨ Hot restart with full process management (< 1 second)
- ✨ Smart change detection (automatic reload vs restart)
- ✨ File watching with debouncing (500ms)
- ✨ CLI tool (`fletch dev`)
- ✨ Automatic VM service connection
- ✨ Graceful error handling with fallback
- ✨ Clean console output with emojis
- 📝 Comprehensive README and documentation

### Features

- **Hot Reload**: Updates code instantly without restarting, preserves application state
- **Hot Restart**: Full process restart when hot reload isn't safe
- **Change Analyzer**: Automatically determines whether to reload or restart based on file type
- **File Watcher**: Monitors `lib/` and other directories for changes
- **Process Manager**: Manages child Dart process lifecycle
- **VM Service Integration**: Connects to Dart VM for code reloading

### CLI Commands

```bash
fletch dev --entry bin/main.dart
fletch dev --entry bin/main.dart --port 8080
fletch dev --entry bin/main.dart --watch lib,routes
```

### Dependencies

- `fletch`: ^2.0.2
- `watcher`: ^1.1.0
- `vm_service`: ^14.2.5
- `args`: ^2.6.0
- `io`: ^1.0.4
