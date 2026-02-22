# Auth Service Example

A production-ready example demonstrating how to build modular authentication services using Fletch's `IsolatedContainer`.

[Join the Discord Community](https://discord.gg/KcYqdtxK) 🎮

## Features

- **Modular Architecture**: Authentication logic is encapsulated in `AuthModule`.
- **Dependency Injection**: Uses scoped `UserService` within the isolated container.
- **Session Management**: Leverages the main application's session store.
- **Mounting**: Demonstrates `app.mount()` and `withPrefix()` features.

## Project Structure

```
lib/
  src/
    auth_module.dart  # The reusable IsolatedContainer
    user_service.dart # Mock user database
bin/
  server.dart         # Main entry point mounting the module
```

## Running the Example

1.  Get dependencies:
    ```bash
    dart pub get
    ```

2.  Run the server:
    ```bash
    dart bin/server.dart
    ```

## Testing the API

**1. Main App (Home)**
```bash
curl http://localhost:8080/
```

**2. Register a User**
```bash
curl -X POST http://localhost:8080/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "password": "password123"}'
```

**3. Login (Save Cookies)**
```bash
curl -c cookies.txt -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "password": "password123"}'
```

**4. Check Profile (Protected Route - Use Cookies)**
```bash
curl -b cookies.txt http://localhost:8080/auth/me
```

**5. Logout**
```bash
curl -b cookies.txt -X POST http://localhost:8080/auth/logout
```
