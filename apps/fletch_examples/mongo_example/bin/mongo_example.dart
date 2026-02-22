import 'dart:io';

import 'package:fletch/fletch.dart';
import 'package:mongo_dart/mongo_dart.dart' as mongo;
import 'package:mongo_pool/mongo_pool.dart';

void main(List<String> arguments) async {
  var app = Fletch();

  app.setErrorHandler((err, req, res) async {
    print(err);
  });

  app.get('/users', (req, res) async {
    String projectPath = Directory.current.path;
    var file = File('$projectPath\\public\\download.jpeg');
    print('File exists: ${await file.exists()}');
    print(file.path);
    var bytes = await file.readAsBytes();
    res.bytes(bytes, contentType: 'image/jpeg');
  });
  app.get('/users1', (req, res) async {
    String projectPath = Directory.current.path;
    var file = File('$projectPath\\public\\Kartikey-Mahawar.pdf');
    print('File exists: ${await file.exists()}');
    print(file.path);

    await res.file(file);
  });
  var mongoCl = MongoService();
  mongoCl.initialize().then((val) {
    print('mongo initialized');
    app.inject<MongoService>(mongoCl);
    app.useController('/mongo', MongoController());
  });

  var envPort = const int.fromEnvironment('port');
  var port = envPort != 0 ? envPort : 8080;
  await app.listen(port);
}

class MongoController extends Controller {
  @override
  void registerRoutes(ControllerOptions options) {
    options.post('/login', loginHandler);
    options.get('/hi', (req, res) {
      res.text('Hi there');
    });
  }

  @override
  void initialize(BaseContainer app, {required String prefix}) {
    // TODO: implement initialize
    super.initialize(app, prefix: prefix);
  }

  loginHandler(Request req, Response res) async {
    var watch = Stopwatch()..start();
    MongoService mongoService = req.container.get<MongoService>();

    var data = await mongoService.db.collection('faculties').find().toList();
    print(watch.elapsedMilliseconds);
    print(data);
    watch.stop();
    res.json({'data': data});
  }
}

class MongoService {
  late final MongoDbPoolService _poolService;
  late mongo.Db db;
  MongoService() {
    _poolService = MongoDbPoolService(
      const MongoPoolConfiguration(
        /// [maxLifetimeMilliseconds] is the maximum lifetime of a connection in the pool.
        /// Connection pools can dynamically expand when faced with high demand. Unused
        /// connections within a specified period are automatically removed, and the pool
        /// size is reduced to the specified minimum when connections (poolSize) are not reused within
        /// that timeframe.
        maxLifetimeMilliseconds: 180000,

        /// [leakDetectionThreshold] is the threshold for connection leak detection.
        /// If the connection is not released within the specified time, it is
        /// considered as a leak.
        /// It won't work if no value is set. It is recommended to set a value
        leakDetectionThreshold: 10000,
        uriString:
            'mongodb+srv://kartikey321:kartikey321@cluster0.ykqbrjy.mongodb.net/srm_connect',

        /// [poolSize] is the minimum number of connections in the pool.
        poolSize: 2,
        secure: false,
      ),
    );
  }

  Future<void> initialize() async {
    try {
      Stopwatch watch = Stopwatch()..start();
      await _poolService.initialize();
      db = await _poolService.acquire();
      print('${watch.elapsed.inSeconds} seconds');
      watch.stop();
    } catch (e) {
      rethrow;
    } finally {
      _poolService.release(db);
    }
  }
}
