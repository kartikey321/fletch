import 'dart:async';

// GLOBAL STATE - Should be preserved!
int globalCounter = 0;

void main() {
  print('The Dart VM service is listening on ' + (Uri.base.toString())); // Placeholder, usually prints automatically
  
  Timer.periodic(Duration(seconds: 1), (timer) {
    globalCounter++;
    print(generateMessage());
  });
}

// Method we will change
String generateMessage() {
  return "[Version 1 (Old)] Count: $globalCounter";
}
