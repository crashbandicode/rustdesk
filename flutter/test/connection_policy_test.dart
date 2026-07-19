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

    test('recognizes an elapsed direct-connect deadline after resume', () {
      expect(
        isTransientMobileNetworkError(
          type: 'relay-hint2',
          title: 'Connection Error',
          text: 'deadline has elapsed',
        ),
        isTrue,
      );
    });

    test('recognizes an unclean WebSocket reset', () {
      expect(
        isTransientMobileNetworkError(
          type: 'error',
          title: 'Connection Error',
          text: 'WebSocket protocol error: Connection reset without '
              'closing handshake',
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

    test('does not reinterpret an unrelated relay hint', () {
      expect(
        isTransientMobileNetworkError(
          type: 'relay-hint',
          title: 'Connection Error',
          text: 'Remote desktop is offline',
        ),
        isFalse,
      );
    });
  });

  group('shouldAutoRecoverTransientMobileNetworkError', () {
    test('keeps the first direct-connect timeout user-visible', () {
      expect(
        shouldAutoRecoverTransientMobileNetworkError(
          type: 'relay-hint2',
          title: 'Connection Error',
          text: 'deadline has elapsed',
          hasEverConnected: false,
        ),
        isFalse,
      );
    });

    test('automatically repairs a timeout after a working connection', () {
      expect(
        shouldAutoRecoverTransientMobileNetworkError(
          type: 'relay-hint2',
          title: 'Connection Error',
          text: 'deadline has elapsed',
          hasEverConnected: true,
        ),
        isTrue,
      );
    });

    test('initial DNS restoration failures still retry automatically', () {
      expect(
        shouldAutoRecoverTransientMobileNetworkError(
          type: 'error',
          title: 'Connection Error',
          text: 'No address associated with hostname',
          hasEverConnected: false,
        ),
        isTrue,
      );
    });
  });

  test('connection transport labels distinguish direct and relay', () {
    expect(connectionTransportLabel(true), 'Connected peer-to-peer');
    expect(connectionTransportLabel(false), 'Connected over relay');
  });
}
