# MongoDB Example for Fletch

A complete MongoDB CRUD (Create, Read, Update, Delete) REST API example built with Fletch.

## Features

- ✅ Full CRUD operations for users
- ✅ RESTful API design
- ✅ Pagination support
- ✅ Input validation
- ✅ Error handling
- ✅ MongoDB indexing
- ✅ Environment variable configuration

## Prerequisites

- Dart SDK 3.6.0 or higher
- MongoDB server (local or cloud)

## Setup

### 1. Install MongoDB

**Local MongoDB:**
```bash
# macOS
brew install mongodb-community

# Start MongoDB
brew services start mongodb-community
```

**Cloud MongoDB:**
- Use [MongoDB Atlas](https://www.mongodb.com/cloud/atlas) (free tier available)

### 2. Configure Connection

Set the MongoDB connection string via environment variable:

```bash
export MONGO_URL="mongodb://localhost:27017/fletch_example"
```

Or for MongoDB Atlas:
```bash
export MONGO_URL="mongodb+srv://username:password@cluster.mongodb.net/fletch_example"
```

### 3. Install Dependencies

```bash
dart pub get
```

### 4. Run the Server

```bash
dart run bin/mongo_example.dart
```

Server will start on `http://localhost:8080`

## API Endpoints

### Health Check
```bash
GET /health
```

### Get All Users (with pagination)
```bash
GET /api/users?page=1&limit=10
```

**Response:**
```json
{
  "success": true,
  "data": [...],
  "pagination": {
    "page": 1,
    "limit": 10,
    "total": 50,
    "pages": 5
  }
}
```

### Get User by ID
```bash
GET /api/users/:id
```

**Response:**
```json
{
  "success": true,
  "data": {
    "_id": "507f1f77bcf86cd799439011",
    "name": "John Doe",
    "email": "john@example.com",
    "age": 30,
    "createdAt": "2024-01-01T00:00:00.000Z",
    "updatedAt": "2024-01-01T00:00:00.000Z"
  }
}
```

### Create User
```bash
POST /api/users
Content-Type: application/json

{
  "name": "John Doe",
  "email": "john@example.com",
  "age": 30
}
```

**Response:**
```json
{
  "success": true,
  "message": "User created successfully",
  "data": {...}
}
```

### Update User
```bash
PUT /api/users/:id
Content-Type: application/json

{
  "name": "John Smith",
  "age": 31
}
```

### Delete User
```bash
DELETE /api/users/:id
```

**Response:**
```json
{
  "success": true,
  "message": "User deleted successfully",
  "data": {...}
}
```

## Testing with cURL

```bash
# Create a user
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "email": "alice@example.com", "age": 28}'

# Get all users
curl http://localhost:8080/api/users

# Get user by ID
curl http://localhost:8080/api/users/507f1f77bcf86cd799439011

# Update user
curl -X PUT http://localhost:8080/api/users/507f1f77bcf86cd799439011 \
  -H "Content-Type: application/json" \
  -d '{"age": 29}'

# Delete user
curl -X DELETE http://localhost:8080/api/users/507f1f77bcf86cd799439011
```

## Project Structure

```
mongo_example/
├── bin/
│   └── mongo_example.dart  # Main application with all CRUD logic
├── pubspec.yaml            # Dependencies
└── README.md               # This file
```

## Error Handling

All endpoints return consistent error responses:

```json
{
  "success": false,
  "error": "Error message here"
}
```

HTTP status codes:
- `200` - Success
- `201` - Created
- `400` - Bad Request
- `404` - Not Found
- `409` - Conflict (duplicate email)
- `500` - Internal Server Error

## What This Example Demonstrates

1. **MongoDB Integration** - Connecting to MongoDB using `mongo_dart`
2. **Dependency Injection** - Injecting `MongoService` into the app
3. **Controllers** - Using Fletch controllers to organize routes
4. **CRUD Operations** - Full create, read, update, delete functionality
5. **Validation** - Input validation and error handling
6. **Pagination** - Query parameter-based pagination
7. **REST API Design** - Proper HTTP methods and status codes
8. **Environment Configuration** - Using environment variables for settings

## Next Steps

- Add authentication (JWT tokens)
- Implement more complex queries and filters
- Add data validation schemas
- Create relationships between collections
- Add middleware for logging
- Write tests for the API endpoints
