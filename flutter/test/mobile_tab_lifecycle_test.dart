import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/remote_tab_lifecycle.dart';

class _SessionProbe extends StatefulWidget {
  const _SessionProbe(
      {required super.key, required this.id, required this.log});

  final String id;
  final List<String> log;

  @override
  State<_SessionProbe> createState() => _SessionProbeState();
}

class _SessionProbeState extends State<_SessionProbe> {
  @override
  void initState() {
    super.initState();
    widget.log.add('init:${widget.id}');
  }

  @override
  void dispose() {
    widget.log.add('dispose:${widget.id}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}

Widget _sessionStack(List<String> ids, int selected, List<String> log) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: StableMobileSessionStack(
      selectedIndex: selected,
      children: [
        for (final id in ids)
          _SessionProbe(key: ValueKey(id), id: id, log: log),
      ],
    ),
  );
}

MobileSessionLifecycleTarget _target(String id, List<String> events) {
  return MobileSessionLifecycleTarget(sessionId: id, peerId: 'peer-$id')
    ..attach(
      onPaused: () => events.add('pause:$id'),
      onResumed: () => events.add('resume:$id'),
      onEnsureHealthy: () => events.add('health:$id'),
    );
}

void main() {
  testWidgets('removing a leading tab preserves the surviving session state', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_sessionStack(['first', 'yoga'], 1, log));
    expect(log, ['init:first', 'init:yoga']);

    log.clear();
    await tester.pumpWidget(_sessionStack(['yoga'], 0, log));

    expect(log, ['dispose:first']);
    expect(find.text('yoga'), findsOneWidget);
  });

  test('mobile input lifecycle releases modifiers at focus boundaries', () {
    final releases = <String>[];
    final guard = MobileInputLifecycleGuard(
      active: true,
      releaseModifiers: releases.add,
    );

    guard.setActive(false);
    guard.setActive(false);
    guard.setActive(true);
    guard.pause();
    guard.dispose();

    expect(releases, ['tab_inactive', 'app_paused', 'session_disposed']);
  });

  test('inactive and background sessions use the low-power media profile', () {
    final policy = MobileTabMediaPolicy(active: true);

    expect(policy.throttled, isFalse);
    policy.setActive(false);
    expect(policy.throttled, isTrue);
    policy.pause();
    policy.setActive(true);
    expect(policy.throttled, isTrue);
    policy.resume();
    expect(policy.throttled, isFalse);
  });

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

  test('selected tab can request a transport health check', () {
    final events = <String>[];
    final target = _target('yoga', events);

    expect(target.ensureHealthy(), isTrue);
    expect(events, ['health:yoga']);
    target.detach();
    expect(target.ensureHealthy(), isFalse);
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

    await tester.pump(const Duration(milliseconds: 1999));
    expect(events, ['resume:selected']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(events, ['resume:selected', 'resume:first']);
    await tester.pump(const Duration(seconds: 2));
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
