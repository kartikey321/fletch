import 'package:fletch/fletch.dart';
import 'package:test/test.dart';

import '../helpers/test_server_harness.dart';

void main() {
  group('Rate limiter middleware', () {
    late TestServerHarness harness;

    setUp(() => harness = TestServerHarness());
    tearDown(() => harness.dispose());

    test('allows requests under the limit', () async {
      harness.app.use(harness.app.rateLimiter(maxRequests: 10));
      harness.app.get('/api', (req, res) => res.text('ok'));

      final r = await harness.get('/api');
      expect(r.statusCode, 200);
    });

    test('returns 429 when limit is exceeded', () async {
      harness.app.use(harness.app.rateLimiter(
        maxRequests: 2,
        window: const Duration(minutes: 1),
      ));
      harness.app.get('/limited', (req, res) => res.text('ok'));

      await harness.get('/limited');
      await harness.get('/limited');
      final r = await harness.get('/limited'); // 3rd request exceeds limit
      expect(r.statusCode, 429);
      expect(r.body, contains('Rate limit exceeded'));
    });

    test('custom keyGenerator is used for bucketing', () async {
      harness.app.use(harness.app.rateLimiter(
        maxRequests: 1,
        keyGenerator: (req) => req.headers.value('x-user-id') ?? 'anon',
      ));
      harness.app.get('/keyed', (req, res) => res.text('ok'));

      // user-a: first request allowed
      final r1 = await harness.get('/keyed', headers: {'x-user-id': 'user-a'});
      expect(r1.statusCode, 200);

      // user-a: second request blocked
      final r2 = await harness.get('/keyed', headers: {'x-user-id': 'user-a'});
      expect(r2.statusCode, 429);

      // user-b: first request allowed (different key)
      final r3 = await harness.get('/keyed', headers: {'x-user-id': 'user-b'});
      expect(r3.statusCode, 200);
    });

    test('custom store is accepted and not auto-tracked', () async {
      final store = MemoryRateLimitStore();
      harness.app.use(harness.app.rateLimiter(
        maxRequests: 5,
        store: store,
      ));
      harness.app.get('/custom-store', (req, res) => res.text('ok'));

      final r = await harness.get('/custom-store');
      expect(r.statusCode, 200);
      store.dispose();
    });
  });

  group('MemoryRateLimitStore', () {
    test('reset() clears counters for a key', () async {
      final store = MemoryRateLimitStore();

      // Fill up to limit
      await store.increment('key', 2, const Duration(minutes: 1));
      await store.increment('key', 2, const Duration(minutes: 1));
      final blocked = await store.increment('key', 2, const Duration(minutes: 1));
      expect(blocked, isFalse);

      // Reset and try again
      await store.reset('key');
      final allowed = await store.increment('key', 2, const Duration(minutes: 1));
      expect(allowed, isTrue);

      store.dispose();
    });

    test('reset() on non-existent key does not throw', () async {
      final store = MemoryRateLimitStore();
      await expectLater(store.reset('ghost'), completes);
      store.dispose();
    });

    test('cleanup timer runs and removes expired entries', () async {
      final store = MemoryRateLimitStore(
        cleanupInterval: const Duration(milliseconds: 50),
        keyExpiry: const Duration(milliseconds: 10),
      );

      await store.increment('expiring', 100, const Duration(seconds: 10));

      // Wait for cleanup to fire
      await Future.delayed(const Duration(milliseconds: 200));

      // After expiry + cleanup, the slot should be fresh
      final allowed = await store.increment('expiring', 1, const Duration(seconds: 10));
      expect(allowed, isTrue);

      store.dispose();
    });
  });
}
