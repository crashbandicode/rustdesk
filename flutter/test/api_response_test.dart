import 'package:flutter_hbb/models/api_response.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('apiResponseError', () {
    test('accepts successful RustDesk-compatible error sentinels', () {
      expect(apiResponseError(<String, dynamic>{}), isNull);
      expect(apiResponseError(<String, dynamic>{'error': null}), isNull);
      expect(apiResponseError(<String, dynamic>{'error': false}), isNull);
      expect(apiResponseError(<String, dynamic>{'error': ''}), isNull);
      expect(apiResponseError(<String, dynamic>{'error': '   '}), isNull);
    });

    test('preserves real server error values', () {
      expect(apiResponseError(<String, dynamic>{'error': true}), isTrue);
      expect(apiResponseError(<String, dynamic>{'error': 'denied'}), 'denied');
      expect(
        apiResponseError(<String, dynamic>{
          'error': <String, dynamic>{'code': 'denied'}
        }),
        <String, dynamic>{'code': 'denied'},
      );
    });

    test('ignores non-map payloads until schema validation handles them', () {
      expect(apiResponseError(null), isNull);
      expect(apiResponseError(false), isNull);
      expect(apiResponseError(<dynamic>[]), isNull);
    });
  });
}
