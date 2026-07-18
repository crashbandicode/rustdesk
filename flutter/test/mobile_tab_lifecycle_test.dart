import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/remote_tab_lifecycle.dart';

MobileSessionLifecycleTarget _target(String id, List<String> events) {
  return MobileSessionLifecycleTarget(sessionId: id, peerId: 'peer-$id')
    ..attach(
      onPaused: () => events.add('pause:$id'),
      onResumed: () => events.add('resume:$id'),
    );
}

void main() {
  test('closing one tab requests only its native session once', () {
    final closed = <String>[];
    final coordinator = MobileSessionCloseCoordinator<String>(
      onCloseRequested: closed.add,
    );

    expect(coordinator.request('yoga-session'), isTrue);
    expect(coordinator.wasRequested('yoga-session'), isTrue);
    expect(coordinator.wasRequested('butterbridge-session'), isFalse);
    expect(closed, ['yoga-session']);

    expect(coordinator.request('yoga-session'), isFalse);
    expect(closed, ['yoga-session']);

    expect(coordinator.request('butterbridge-session'), isTrue);
    expect(closed, ['yoga-session', 'butterbridge-session']);
  });

  testWidgets('selected tab resumes first and live siblings are staggered', (
    tester,
  ) async {
    final events = <String>[];
    final first = _target('first', events);
    final selected = _target('selected', events);
    final third = _target('third', events);
    final coordinator = MobileTabLifecycleCoordinator();
    final targets = [first, selected, third];

    expect(coordinator.pauseAll(targets), isTrue);
    expect(events, ['pause:first', 'pause:selected', 'pause:third']);
    events.clear();

    expect(coordinator.resumeAll(targets, selected: selected), isTrue);
    expect(events, ['resume:selected']);

    await tester.pump(const Duration(milliseconds: 249));
    expect(events, ['resume:selected']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(events, ['resume:selected', 'resume:first']);
    await tester.pump(const Duration(milliseconds: 250));
    expect(events, ['resume:selected', 'resume:first', 'resume:third']);

    coordinator.dispose();
  });

  testWidgets('selecting a pending tab promotes it without duplicate resume', (
    tester,
  ) async {
    final events = <String>[];
    final selected = _target('selected', events);
    final pending = _target('pending', events);
    final coordinator = MobileTabLifecycleCoordinator();
    final targets = [selected, pending];

    coordinator.pauseAll(targets);
    events.clear();
    coordinator.resumeAll(targets, selected: selected);
    expect(events, ['resume:selected']);

    expect(coordinator.prioritize(pending), isTrue);
    expect(events, ['resume:selected', 'resume:pending']);
    await tester.pump(const Duration(seconds: 1));
    expect(events, ['resume:selected', 'resume:pending']);
    expect(coordinator.prioritize(pending), isFalse);

    coordinator.dispose();
  });

  testWidgets('repeated lifecycle states are coalesced', (tester) async {
    final events = <String>[];
    final target = _target('only', events);
    final coordinator = MobileTabLifecycleCoordinator();

    expect(coordinator.pauseAll([target]), isTrue);
    expect(coordinator.pauseAll([target]), isFalse);
    expect(events, ['pause:only']);
    expect(coordinator.resumeAll([target], selected: target), isTrue);
    expect(coordinator.resumeAll([target], selected: target), isFalse);
    expect(events, ['pause:only', 'resume:only']);

    coordinator.dispose();
  });

  test('hidden frame policy stays warm without decoding every frame', () {
    final policy = MobileTabFrameDecodePolicy();
    final start = DateTime.utc(2026, 7, 18);

    expect(policy.shouldDecode(start), isTrue);
    policy.setActive(false);
    expect(policy.shouldDecode(start), isTrue);
    expect(
      policy.shouldDecode(start.add(const Duration(milliseconds: 999))),
      isFalse,
    );
    expect(policy.shouldDecode(start.add(const Duration(seconds: 1))), isTrue);
    policy.setActive(true);
    expect(policy.shouldDecode(start.add(const Duration(seconds: 1))), isTrue);
    expect(
      policy.shouldDecode(start.add(const Duration(milliseconds: 1001))),
      isTrue,
    );
  });
}
