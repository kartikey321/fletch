import 'dart:convert';
import 'package:fletch/fletch.dart';

Future<void> main() async {
  final app = Fletch();

  // Basic SSE endpoint
  app.get('/events', (req, res) async {
    await res.sse((sink) async {
      // Send initial event
      await sink.sendEvent('Connected to SSE stream');

      // Send events with different types
      await sink.sendEvent('This is a notification', event: 'notification');
      await sink.sendEvent(jsonEncode({'user': 'Alice', 'action': 'login'}),
          event: 'user-activity', id: '1');

      // Stream updates
      for (var i = 1; i <= 10; i++) {
        await Future.delayed(Duration(seconds: 1));
        await sink.sendEvent('Update $i', id: i.toString());
      }

      await sink.sendEvent('Stream complete', event: 'done');
      sink.close();
    });
  });

  // SSE with keep-alive
  app.get('/live-updates', (req, res) async {
    await res.sse(
      (sink) async {
        // This will run for 60 seconds
        final endTime = DateTime.now().add(Duration(seconds: 60));

        while (DateTime.now().isBefore(endTime) && !sink.isClosed) {
          final data = {
            'timestamp': DateTime.now().toIso8601String(),
            'value': DateTime.now().millisecondsSinceEpoch % 100,
          };

          await sink.sendEvent(jsonEncode(data), event: 'update');
          await Future.delayed(Duration(seconds: 2));
        }

        sink.close();
      },
      keepAlive: Duration(seconds: 15), // Send keep-alive every 15 seconds
    );
  });

  // SSE with real-time notifications
  app.get('/notifications', (req, res) async {
    await res.sse((sink) async {
      // Simulate real-time notifications
      final notifications = [
        'New message from Alice',
        'Bob liked your post',
        'Your order has shipped',
        'Meeting reminder: 3 PM',
      ];

      for (var notification in notifications) {
        await Future.delayed(Duration(seconds: 3));
        await sink.sendEvent(
          jsonEncode({
            'message': notification,
            'time': DateTime.now().toIso8601String()
          }),
          event: 'notification',
          id: DateTime.now().millisecondsSinceEpoch.toString(),
        );
      }

      // Keep connection open for more notifications
      await Future.delayed(Duration(seconds: 30));
      sink.close();
    });
  });

  // HTML page to test SSE
  app.get('/', (req, res) {
    res.html('''
<!DOCTYPE html>
<html>
<head>
  <title>Fletch SSE Example</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; }
    .event { padding: 10px; margin: 5px 0; background: #f0f0f0; border-radius: 4px; }
    .event.notification { background: #e3f2fd; }
    .event.update { background: #f3e5f5; }
    button { padding: 10px 20px; margin: 10px 5px; cursor: pointer; }
  </style>
</head>
<body>
  <h1>Fletch SSE Example</h1>
  
  <div>
    <button onclick="connectBasic()">Connect to /events</button>
    <button onclick="connectLive()">Connect to /live-updates</button>
    <button onclick="connectNotifications()">Connect to /notifications</button>
    <button onclick="disconnect()">Disconnect</button>
  </div>
  
  <h2>Events:</h2>
  <div id="events"></div>
  
  <script>
    let eventSource = null;
    
    function addEvent(message, type = '') {
      const div = document.createElement('div');
      div.className = 'event ' + type;
      div.textContent = new Date().toLocaleTimeString() + ': ' + message;
      document.getElementById('events').prepend(div);
    }
    
    function connectBasic() {
      disconnect();
      eventSource = new EventSource('/events');
      
      eventSource.onmessage = (e) => {
        addEvent('Message: ' + e.data);
      };
      
      eventSource.addEventListener('notification', (e) => {
        addEvent('Notification: ' + e.data, 'notification');
      });
      
      eventSource.addEventListener('user-activity', (e) => {
        addEvent('User Activity: ' + e.data, 'update');
      });
      
      eventSource.addEventListener('done', (e) => {
        addEvent('Stream complete!');
        disconnect();
      });
      
      eventSource.onerror = () => {
        addEvent('Connection error');
      };
    }
    
    function connectLive() {
      disconnect();
      eventSource = new EventSource('/live-updates');
      
      eventSource.addEventListener('update', (e) => {
        const data = JSON.parse(e.data);
        addEvent(`Update: \${data.value} at \${data.timestamp}`, 'update');
      });
      
      eventSource.onerror = () => {
        addEvent('Connection error');
      };
    }
    
    function connectNotifications() {
      disconnect();
      eventSource = new EventSource('/notifications');
      
      eventSource.addEventListener('notification', (e) => {
        const data = JSON.parse(e.data);
        addEvent(data.message, 'notification');
      });
      
      eventSource.onerror = () => {
        addEvent('Connection error');
      };
    }
    
    function disconnect() {
      if (eventSource) {
        eventSource.close();
        eventSource = null;
        addEvent('Disconnected');
      }
    }
  </script>
</body>
</html>
    ''');
  });

  await app.listen(8080);
  print('SSE example running on http://localhost:8080');
  print('Open in browser to test Server-Sent Events');
}
