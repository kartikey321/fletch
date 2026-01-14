import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:mongo_dart/mongo_dart.dart' as mongo;

void main() async {
  final app = Fletch();

  // Initialize MongoDB connection
  final mongoService = MongoService();
  await mongoService.initialize();
  app.inject<MongoService>(mongoService);

  // Register controller
  app.useController('/api/users', UserController());

  // Health check endpoint
  app.get('/health', (req, res) {
    res.json({'status': 'ok', 'message': 'MongoDB Example Server'});
  });

  // Error handler
  app.setErrorHandler((error, req, res) async {
    print('Error: $error');
    res.status(500).json({'error': error.toString()});
  });

  final port = int.fromEnvironment('PORT', defaultValue: 8080);
  await app.listen(port);
  print('🚀 Server running on http://localhost:$port');
  print('📚 MongoDB CRUD API available at /api/users');
}

/// MongoDB Service for database operations
class MongoService {
  late mongo.Db db;
  late mongo.DbCollection usersCollection;

  Future<void> initialize() async {
    try {
      // Use environment variable for connection string in production
      final connectionString = Platform.environment['MONGO_URL'] ??
          'mongodb://localhost:27017/fletch_example';

      db = mongo.Db(connectionString);
      await db.open();

      usersCollection = db.collection('users');

      print('✅ MongoDB connected successfully');

      // Create index on email for uniqueness
      await usersCollection.createIndex(
        key: 'email',
        unique: true,
      );
    } catch (e) {
      print('❌ MongoDB connection failed: $e');
      rethrow;
    }
  }

  Future<void> close() async {
    await db.close();
  }
}

/// User Controller - Handles CRUD operations for users
class UserController extends Controller {
  @override
  void registerRoutes(ControllerOptions options) {
    options.get('/', getAllUsers);
    options.get('/:id', getUserById);
    options.post('/', createUser);
    options.put('/:id', updateUser);
    options.delete('/:id', deleteUser);
  }

  /// GET /api/users - Get all users
  Future<void> getAllUsers(Request req, Response res) async {
    try {
      final mongoService = req.container.get<MongoService>();

      // Support pagination
      final page = int.tryParse(req.query['page'] ?? '1') ?? 1;
      final limit = int.tryParse(req.query['limit'] ?? '10') ?? 10;
      final skip = (page - 1) * limit;

      final users = await mongoService.usersCollection
          .find()
          .skip(skip)
          .take(limit)
          .toList();

      final total = await mongoService.usersCollection.count();

      res.json({
        'success': true,
        'data': users,
        'pagination': {
          'page': page,
          'limit': limit,
          'total': total,
          'pages': (total / limit).ceil(),
        }
      });
    } catch (e) {
      res.status(500).json({'success': false, 'error': e.toString()});
    }
  }

  /// GET /api/users/:id - Get user by ID
  Future<void> getUserById(Request req, Response res) async {
    try {
      final id = req.params['id'];
      if (id == null) {
        return res
            .status(400)
            .json({'success': false, 'error': 'User ID is required'});
      }

      final mongoService = req.container.get<MongoService>();
      final user = await mongoService.usersCollection.findOne(
        mongo.where.id(mongo.ObjectId.fromHexString(id)),
      );

      if (user == null) {
        return res
            .status(404)
            .json({'success': false, 'error': 'User not found'});
      }

      res.json({'success': true, 'data': user});
    } catch (e) {
      res.status(500).json({'success': false, 'error': e.toString()});
    }
  }

  /// POST /api/users - Create a new user
  Future<void> createUser(Request req, Response res) async {
    try {
      final bodyData = await req.body;
      if (bodyData is! Map<String, dynamic>) {
        return res
            .status(400)
            .json({'success': false, 'error': 'Invalid request body'});
      }
      final body = bodyData;

      // Validate required fields
      if (body['name'] == null || body['email'] == null) {
        return res
            .status(400)
            .json({'success': false, 'error': 'Name and email are required'});
      }

      final mongoService = req.container.get<MongoService>();

      // Check if email already exists
      final existing = await mongoService.usersCollection.findOne(
        mongo.where.eq('email', body['email']),
      );

      if (existing != null) {
        return res
            .status(409)
            .json({'success': false, 'error': 'Email already exists'});
      }

      // Create user document
      final user = {
        'name': body['name'],
        'email': body['email'],
        'age': body['age'],
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final result = await mongoService.usersCollection.insertOne(user);

      if (result.isSuccess) {
        final createdUser = await mongoService.usersCollection.findOne(
          mongo.where.id(result.id),
        );

        res.status(201).json({
          'success': true,
          'message': 'User created successfully',
          'data': createdUser,
        });
      } else {
        res
            .status(500)
            .json({'success': false, 'error': 'Failed to create user'});
      }
    } catch (e) {
      res.status(500).json({'success': false, 'error': e.toString()});
    }
  }

  /// PUT /api/users/:id - Update user
  Future<void> updateUser(Request req, Response res) async {
    try {
      final id = req.params['id'];
      if (id == null) {
        return res
            .status(400)
            .json({'success': false, 'error': 'User ID is required'});
      }

      final bodyData = await req.body;
      if (bodyData is! Map<String, dynamic>) {
        return res
            .status(400)
            .json({'success': false, 'error': 'Invalid request body'});
      }
      final body = bodyData;
      final mongoService = req.container.get<MongoService>();

      // Check if user exists
      final existing = await mongoService.usersCollection.findOne(
        mongo.where.id(mongo.ObjectId.fromHexString(id)),
      );

      if (existing == null) {
        return res
            .status(404)
            .json({'success': false, 'error': 'User not found'});
      }

      // Prepare update data
      final updateData = <String, dynamic>{};
      if (body['name'] != null) updateData['name'] = body['name'];
      if (body['email'] != null) updateData['email'] = body['email'];
      if (body['age'] != null) updateData['age'] = body['age'];
      updateData['updatedAt'] = DateTime.now().toIso8601String();

      final result = await mongoService.usersCollection.updateOne(
        mongo.where.id(mongo.ObjectId.fromHexString(id)),
        mongo.modify
            .set('name', updateData['name'] ?? existing['name'])
            .set('email', updateData['email'] ?? existing['email'])
            .set('age', updateData['age'] ?? existing['age'])
            .set('updatedAt', updateData['updatedAt']),
      );

      if (result.isSuccess) {
        final updatedUser = await mongoService.usersCollection.findOne(
          mongo.where.id(mongo.ObjectId.fromHexString(id)),
        );

        res.json({
          'success': true,
          'message': 'User updated successfully',
          'data': updatedUser,
        });
      } else {
        res
            .status(500)
            .json({'success': false, 'error': 'Failed to update user'});
      }
    } catch (e) {
      res.status(500).json({'success': false, 'error': e.toString()});
    }
  }

  /// DELETE /api/users/:id - Delete user
  Future<void> deleteUser(Request req, Response res) async {
    try {
      final id = req.params['id'];
      if (id == null) {
        return res
            .status(400)
            .json({'success': false, 'error': 'User ID is required'});
      }

      final mongoService = req.container.get<MongoService>();

      // Check if user exists
      final existing = await mongoService.usersCollection.findOne(
        mongo.where.id(mongo.ObjectId.fromHexString(id)),
      );

      if (existing == null) {
        return res
            .status(404)
            .json({'success': false, 'error': 'User not found'});
      }

      final result = await mongoService.usersCollection.deleteOne(
        mongo.where.id(mongo.ObjectId.fromHexString(id)),
      );

      if (result.isSuccess) {
        res.json({
          'success': true,
          'message': 'User deleted successfully',
          'data': existing,
        });
      } else {
        res
            .status(500)
            .json({'success': false, 'error': 'Failed to delete user'});
      }
    } catch (e) {
      res.status(500).json({'success': false, 'error': e.toString()});
    }
  }
}
