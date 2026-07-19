bool mobileOutgoingSessionKeepaliveEnabledFromOption(String value) =>
    value == 'Y';

class MobileOutgoingSessionKeepaliveSnapshot {
  const MobileOutgoingSessionKeepaliveSnapshot({
    required this.sessionCount,
    required this.enabled,
  });

  final int sessionCount;
  final bool enabled;

  int get effectiveSessionCount => enabled ? sessionCount : 0;
}

typedef MobileOutgoingSessionKeepalivePublisher =
    Future<void> Function(MobileOutgoingSessionKeepaliveSnapshot snapshot);

/// Tracks outgoing sessions independently from the user's keepalive choice.
///
/// Keeping the real count while disabled lets a settings change take effect
/// immediately if the tab host is still mounted: enabling starts the lease and
/// disabling stops it without waiting for another session lifecycle event.
class MobileOutgoingSessionKeepaliveCoordinator {
  MobileOutgoingSessionKeepaliveCoordinator({
    required bool Function() isEnabled,
    required MobileOutgoingSessionKeepalivePublisher publish,
  }) : _isEnabled = isEnabled,
       _publish = publish;

  final bool Function() _isEnabled;
  final MobileOutgoingSessionKeepalivePublisher _publish;
  int _sessionCount = 0;

  int get sessionCount => _sessionCount;

  Future<void> updateSessionCount(int count) {
    _sessionCount = count < 0 ? 0 : count;
    return refresh();
  }

  Future<void> refresh() {
    return _publish(
      MobileOutgoingSessionKeepaliveSnapshot(
        sessionCount: _sessionCount,
        enabled: _isEnabled(),
      ),
    );
  }
}
