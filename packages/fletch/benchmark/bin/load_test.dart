#!/usr/bin/env dart

import 'dart:io';
import 'package:http/http.dart' as http;

/// Simple load testing tool for fletch applications
///
/// Usage:
///   dart run bin/load_test.dart url [requests] [concurrency]
///
/// Example:
///   dart run bin/load_test.dart http://localhost:3000 1000 10

void main(List<String> args) async {
  if (args.isEmpty) {
    print(
        'Usage: dart run bin/load_test.dart <url> [total_requests] [concurrent]');
    print('Example: dart run bin/load_test.dart http://localhost:3000 1000 10');
    exit(1);
  }

  final url = args[0];
  final totalRequests = args.length > 1 ? int.parse(args[1]) : 100;
  final concurrent = args.length > 2 ? int.parse(args[2]) : 10;

  print('🚀 Load Test Configuration');
  print('   URL: $url');
  print('   Total Requests: $totalRequests');
  print('   Concurrent: $concurrent');
  print('');

  final results = await runLoadTest(url, totalRequests, concurrent);

  printResults(results);
}

class LoadTestResults {
  final int totalRequests;
  final int successfulRequests;
  final int failedRequests;
  final Duration totalDuration;
  final List<Duration> responseTimes;

  LoadTestResults({
    required this.totalRequests,
    required this.successfulRequests,
    required this.failedRequests,
    required this.totalDuration,
    required this.responseTimes,
  });

  double get successRate => (successfulRequests / totalRequests) * 100;
  double get requestsPerSecond =>
      totalRequests / totalDuration.inMilliseconds * 1000;

  Duration get averageResponseTime {
    if (responseTimes.isEmpty) return Duration.zero;
    final total = responseTimes.fold<int>(
      0,
      (sum, duration) => sum + duration.inMicroseconds,
    );
    return Duration(microseconds: total ~/ responseTimes.length);
  }

  Duration get minResponseTime => responseTimes.isEmpty
      ? Duration.zero
      : responseTimes.reduce((a, b) => a < b ? a : b);

  Duration get maxResponseTime => responseTimes.isEmpty
      ? Duration.zero
      : responseTimes.reduce((a, b) => a > b ? a : b);

  Duration get p50ResponseTime => _percentile(0.50);
  Duration get p95ResponseTime => _percentile(0.95);
  Duration get p99ResponseTime => _percentile(0.99);

  Duration _percentile(double percentile) {
    if (responseTimes.isEmpty) return Duration.zero;
    final sorted = List<Duration>.from(responseTimes)..sort();
    final index = (sorted.length * percentile).floor();
    return sorted[index.clamp(0, sorted.length - 1)];
  }
}

Future<LoadTestResults> runLoadTest(
  String url,
  int totalRequests,
  int concurrent,
) async {
  final responseTimes = <Duration>[];
  var successCount = 0;
  var failCount = 0;

  final startTime = DateTime.now();

  // Process requests in batches
  for (var batch = 0; batch < totalRequests; batch += concurrent) {
    final batchSize = (batch + concurrent > totalRequests)
        ? totalRequests - batch
        : concurrent;

    final futures = <Future>[];
    for (var i = 0; i < batchSize; i++) {
      futures.add(_makeRequest(url).then((duration) {
        if (duration != null) {
          responseTimes.add(duration);
          successCount++;
        } else {
          failCount++;
        }
      }));
    }

    await Future.wait(futures);

    // Progress indicator
    final progress =
        ((batch + batchSize) / totalRequests * 100).toStringAsFixed(1);
    stdout.write(
        '\r   Progress: $progress% (${batch + batchSize}/$totalRequests)');
  }

  final endTime = DateTime.now();
  print(''); // New line after progress

  return LoadTestResults(
    totalRequests: totalRequests,
    successfulRequests: successCount,
    failedRequests: failCount,
    totalDuration: endTime.difference(startTime),
    responseTimes: responseTimes,
  );
}

Future<Duration?> _makeRequest(String url) async {
  try {
    final startTime = DateTime.now();
    final response = await http.get(Uri.parse(url));
    final endTime = DateTime.now();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return endTime.difference(startTime);
    }
    return null;
  } catch (e) {
    return null;
  }
}

void printResults(LoadTestResults results) {
  print('');
  print('📊 Load Test Results');
  print('=' * 60);
  print('');

  print('📈 Summary:');
  print('   Total Requests: ${results.totalRequests}');
  print('   Successful: ${results.successfulRequests}');
  print('   Failed: ${results.failedRequests}');
  print('   Success Rate: ${results.successRate.toStringAsFixed(2)}%');
  print('   Duration: ${results.totalDuration.inMilliseconds}ms');
  print('   Requests/sec: ${results.requestsPerSecond.toStringAsFixed(2)}');
  print('');

  print('⏱️  Response Times (ms):');
  print('   Average: ${results.averageResponseTime.inMilliseconds}');
  print('   Min: ${results.minResponseTime.inMilliseconds}');
  print('   Max: ${results.maxResponseTime.inMilliseconds}');
  print('   P50 (median): ${results.p50ResponseTime.inMilliseconds}');
  print('   P95: ${results.p95ResponseTime.inMilliseconds}');
  print('   P99: ${results.p99ResponseTime.inMilliseconds}');
  print('');
  print('=' * 60);
}
