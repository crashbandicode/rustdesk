import 'dart:async';

typedef MobileSessionLifecycleCallback = void Function();

class MobileSessionLifecycleTarget {
  MobileSessionLifecycleTarget({
    required this.sessionId,
    required this.peerId,
  });

  final String sessionId;
  final String peerId;

  MobileSessionLifecycleCallback? _onPaused;
  MobileSessionLifecycleCallback? _onResumed;

  bool get attached => _onPaused != null && _onResumed != null;

  void attach({
    required MobileSessionLifecycleCallback onPaused,
    required MobileSessionLifecycleCallback onResumed,
  }) {
    _onPaused = onPaused;
    _onResumed = onResumed;
  }

  void detach() {
    _onPaused = null;
    _onResumed = null;
  }

  void pause() => _onPaused?.call();
  void resume() => _onResumed?.call();
}

class MobileTabLifecycleCoordinator {
  MobileTabLifecycleCoordinator({
    this.resumeStagger = const Duration(milliseconds: 250),
    bool initiallyBackgrounded = false,
  }) : _backgrounded = initiallyBackgrounded;

  final Duration resumeStagger;
  final Map<MobileSessionLifecycleTarget, Timer> _pendingResumes = {};
  bool _backgrounded;

  bool get backgrounded => _backgrounded;

  bool pauseAll(List<MobileSessionLifecycleTarget> targets) {
    if (_backgrounded) return false;
    _backgrounded = true;
    _cancelPendingResumes();
    for (final target in targets) {
      target.pause();
    }
    return true;
  }

  bool resumeAll(
    List<MobileSessionLifecycleTarget> targets, {
    required MobileSessionLifecycleTarget selected,
  }) {
    if (!_backgrounded) return false;
    _backgrounded = false;
    _cancelPendingResumes();

    final ordered = <MobileSessionLifecycleTarget>[
      if (targets.contains(selected)) selected,
      for (final target in targets)
        if (!identical(target, selected)) target,
    ];
    for (var index = 0; index < ordered.length; index++) {
      final target = ordered[index];
      final delay = resumeStagger * index;
      if (delay == Duration.zero) {
        target.resume();
      } else {
        _pendingResumes[target] = Timer(delay, () {
          _pendingResumes.remove(target);
          if (!_backgrounded) target.resume();
        });
      }
    }
    return true;
  }

  bool prioritize(MobileSessionLifecycleTarget target) {
    if (_backgrounded) return false;
    final timer = _pendingResumes.remove(target);
    if (timer == null) return false;
    timer.cancel();
    target.resume();
    return true;
  }

  void remove(MobileSessionLifecycleTarget target) {
    _pendingResumes.remove(target)?.cancel();
  }

  void dispose() => _cancelPendingResumes();

  void _cancelPendingResumes() {
    for (final timer in _pendingResumes.values) {
      timer.cancel();
    }
    _pendingResumes.clear();
  }
}

class MobileTabFrameDecodePolicy {
  MobileTabFrameDecodePolicy({
    this.inactiveDecodeInterval = const Duration(seconds: 1),
  });

  final Duration inactiveDecodeInterval;
  bool _active = true;
  DateTime? _lastInactiveDecode;

  bool get active => _active;

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (active) _lastInactiveDecode = null;
  }

  bool shouldDecode(DateTime now) {
    if (_active) return true;
    final last = _lastInactiveDecode;
    if (last != null && now.difference(last) < inactiveDecodeInterval) {
      return false;
    }
    _lastInactiveDecode = now;
    return true;
  }
}
