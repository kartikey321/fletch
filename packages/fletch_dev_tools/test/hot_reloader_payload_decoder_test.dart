import 'package:fletch_dev_tools/src/hot_reloader.dart';
import 'package:test/test.dart';

void main() {
  group('decodeVmServiceExtensionPayload', () {
    test('returns flat payload map when ok exists at top-level', () {
      final decoded = decodeVmServiceExtensionPayload({
        'ok': true,
        'generationId': 'gen-000001',
      });

      expect(decoded, isNotNull);
      expect(decoded!['ok'], isTrue);
      expect(decoded['generationId'], 'gen-000001');
    });

    test('decodes nested result envelope with json string', () {
      final decoded = decodeVmServiceExtensionPayload({
        'type': 'ServiceExtensionResponse',
        'result': '{"ok":true,"generationId":"gen-000002"}',
      });

      expect(decoded, isNotNull);
      expect(decoded!['ok'], isTrue);
      expect(decoded['generationId'], 'gen-000002');
    });

    test('decodes nested response envelope', () {
      final decoded = decodeVmServiceExtensionPayload({
        'type': 'Success',
        'response': {
          'result': '{"ok":false,"error":"missing generation"}',
        },
      });

      expect(decoded, isNotNull);
      expect(decoded!['ok'], isFalse);
      expect(decoded['error'], contains('missing'));
    });

    test('returns null for non-json strings', () {
      final decoded = decodeVmServiceExtensionPayload('not-json');
      expect(decoded, isNull);
    });
  });
}
