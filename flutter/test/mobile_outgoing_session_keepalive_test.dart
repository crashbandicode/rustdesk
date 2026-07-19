import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/outgoing_session_keepalive_state.dart';

void main() {
  test('background keepalive is opt-in when no option has been stored', () {
    expect(mobileOutgoingSessionKeepaliveEnabledFromOption(''), isFalse);
    expect(mobileOutgoingSessionKeepaliveEnabledFromOption('N'), isFalse);
    expect(mobileOutgoingSessionKeepaliveEnabledFromOption('Y'), isTrue);
  });

  test(
    'disabled keepalive publishes zero while retaining the real count',
    () async {
      var enabled = false;
      final snapshots = <MobileOutgoingSessionKeepaliveSnapshot>[];
      final coordinator = MobileOutgoingSessionKeepaliveCoordinator(
        isEnabled: () => enabled,
        publish: (snapshot) async => snapshots.add(snapshot),
      );

      await coordinator.updateSessionCount(2);

      expect(coordinator.sessionCount, 2);
      expect(snapshots.single.enabled, isFalse);
      expect(snapshots.single.effectiveSessionCount, 0);
    },
  );

  test('changing the option applies immediately to mounted sessions', () async {
    var enabled = false;
    final effectiveCounts = <int>[];
    final coordinator = MobileOutgoingSessionKeepaliveCoordinator(
      isEnabled: () => enabled,
      publish: (snapshot) async {
        effectiveCounts.add(snapshot.effectiveSessionCount);
      },
    );

    await coordinator.updateSessionCount(2);
    enabled = true;
    await coordinator.refresh();
    enabled = false;
    await coordinator.refresh();

    expect(effectiveCounts, [0, 2, 0]);
  });

  test('enabled keepalive follows tab count and stops at zero', () async {
    final effectiveCounts = <int>[];
    final coordinator = MobileOutgoingSessionKeepaliveCoordinator(
      isEnabled: () => true,
      publish: (snapshot) async {
        effectiveCounts.add(snapshot.effectiveSessionCount);
      },
    );

    await coordinator.updateSessionCount(1);
    await coordinator.updateSessionCount(3);
    await coordinator.updateSessionCount(0);

    expect(effectiveCounts, [1, 3, 0]);
  });
}
