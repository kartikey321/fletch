# AST Integration - Testing Steps

## Setup

```bash
# From fletch_dev_tools directory
cd /Users/kartik/StudioProjects/dart_express/packages/fletch_dev_tools
```

## Test 1: Body-Only Change (Should Hot Reload)

1. **Start dev server:**
   ```bash
   dart run bin/fletch.dart --entry example/test_server.dart
   ```

2. **Edit `example/test_server.dart`:**
   - Change message in root route
   - Change version number
   - Add logging statements

3. **Expected output:**
   ```
   📝 File changed: example/test_server.dart
   🔍 Analyzing changes...
      ✅ Function body changed: main [line X]
   🔄 Hot reloading...
   ✅ Hot reload successful (Xms)
   ```

## Test 2: Signature Change (Should Restart)

1. **Edit route handler signature:**
   ```dart
   app.get('/user/:id', (req, res, {bool verbose = false}) {  // Added param
   ```

2. **Expected output:**
   ```
   📝 File changed: example/test_server.dart
   🔍 Analyzing changes...
      ⚠️ Function signature changed: main [line X]
         💡 Restart required - signature change is breaking
   🔄 Hot restarting (Function signature changed: main)...
   🛑 Stopping server...
   ✅ Server stopped
   🚀 Starting server: example/test_server.dart
   ⚡ Restarted in Xms
   ```

## Test 3: Verify with curl

While dev server is running:

```bash
# Test endpoint
curl http://localhost:3003/

# Make body change to test_server.dart
# Verify response changes without restart

# Make signature change
# Verify server restarts
```

## Success Criteria

- ✅ Body changes trigger hot reload (< 200ms)
- ✅ Signature changes trigger restart (~500ms)
- ✅ Server keeps running between changes
- ✅ Changes are reflected immediately
- ✅ Detailed change information shown in console
