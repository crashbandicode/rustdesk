import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/connection_policy.dart';

void main() {
  group('isTransientMobileNetworkError', () {
    test('recognizes the Android resume DNS failure', () {
      expect(
        isTransientMobileNetworkError(
          type: 'error',
          title: 'Connection Error',
          text: 'WebSocket error: IO error: failed to lookup address '
              'information: No address associated with hostname',
        ),
        isTrue,
      );
    });

    test('recognizes a temporarily unreachable network', () {
      expect(
        isTransientMobileNetworkError(
          type: 'error',
          title: 'Connection Error',
          text: 'IO error: Network is unreachable',
        ),
        isTrue,
      );
    });

    test('does not retry permanent authentication failures', () {
      expect(
        isTransientMobileNetworkError(
          type: 'error',
          title: 'Connection Error',
          text: 'Wrong password',
        ),
        isFalse,
      );
    });
  });

  test('connection transport labels distinguish direct and relay', () {
    expect(connectionTransportLabel(true), 'Connected peer-to-peer');
    expect(connectionTransportLabel(false), 'Connected over relay');
  });
}
