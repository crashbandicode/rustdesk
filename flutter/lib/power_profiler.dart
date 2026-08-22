import 'dart:async';
import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'common.dart';
import 'consts.dart';
import 'models/platform_model.dart';

/// A deliberately low-frequency profiler for multi-day power investigations.
/// Native Rust processes collect their own process counters; this companion
/// adds Flutter frame timing, lifecycle, Android battery/power state, and a
/// bounded snapshot of recent session quality.
class PowerProfiler with WidgetsBindingObserver {
  PowerProfiler._();

  static final PowerProfiler instance = PowerProfiler._();
  static const _sampleInterval = Duration(minutes: 1);
  static const _qualityFreshness = Duration(minutes: 2);

  bool _started = false;
  bool _enabled = false;
  bool _frameCallbackInstalled = false;
  AppLifecycleState? _lifecycleState;
  int _frameCount = 0;
  int _buildMicros = 0;
  int _rasterMicros = 0;
  int _worstFrameMicros = 0;
  int _over16ms = 0;
  int _over33ms = 0;
  final Map<String, _QualitySnapshot> _quality = {};
  final Map<String, _MobileSessionSnapshot> _mobileSessions = {};

  static bool get enabled =>
      bind.mainGetOptionSync(key: kOptionPowerProfiling) == 'Y';

  static int get captureStartedMillis => int.tryParse(
        bind.mainGetOptionSync(key: kOptionPowerProfilingStartedAt),
      ) ?? 0;

  static Future<void> setEnabled(bool value) async {
    await bind.mainSetOption(
      key: kOptionPowerProfiling,
      value: value ? 'Y' : 'N',
    );
    instance._setCachedEnabled(value);
    if (value) {
      instance.start();
      await instance.sampleNow(reason: 'local_toggle');
    }
  }

  void start() {
    if (_started) return;
    _started = true;
    _setCachedEnabled(enabled);
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    Timer.periodic(_sampleInterval, (_) => unawaited(sampleNow()));
    Future<void>.delayed(const Duration(seconds: 10), () async {
      if (_started && enabled) await sampleNow(reason: 'startup');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  void registerMobileSession(String sessionId, String peerId, bool active) {
    if (sessionId.isEmpty || peerId.isEmpty) return;
    _mobileSessions[sessionId] = _MobileSessionSnapshot(peerId, active);
  }

  void setMobileSessionActive(String sessionId, bool active) {
    final session = _mobileSessions[sessionId];
    if (session != null) session.active = active;
  }

  void unregisterMobileSession(String sessionId) {
    _mobileSessions.remove(sessionId);
  }

  void recordConnection(
    String sessionId,
    String peerId, {
    required bool direct,
    required String streamType,
  }) {
    if (!isMobile || sessionId.isEmpty) return;
    final session = _mobileSessions.putIfAbsent(
      sessionId,
      () => _MobileSessionSnapshot(peerId, false),
    );
    session.direct = direct;
    session.streamType = streamType;
  }

  void recordQuality(
    String sessionId,
    String peerId,
    Map<String, dynamic> event,
  ) {
    if (!_enabled || sessionId.isEmpty || peerId.isEmpty) return;
    const keys = <String>{
      'speed',
      'fps',
      'delay',
      'target_bitrate',
      'codec_format',
      'chroma',
      'decoder_backends',
      'resolutions',
    };
    final values = <String, Object?>{};
    for (final key in keys) {
      final value = event[key];
      if (value != null && value.toString().isNotEmpty) {
        values[key] = value.toString();
      }
    }
    _quality[sessionId] = _QualitySnapshot(peerId, DateTime.now(), values);
    if (_quality.length > 8) {
      final oldest = _quality.entries.reduce(
        (left, right) => left.value.updated.isBefore(right.value.updated)
            ? left
            : right,
      );
      _quality.remove(oldest.key);
    }
  }

  Future<void> sampleNow({String reason = 'periodic'}) async {
    _setCachedEnabled(enabled);
    if (!_enabled) {
      _resetFrames();
      return;
    }
    final now = DateTime.now();
    _quality.removeWhere(
      (_, sample) => now.difference(sample.updated) > _qualityFreshness,
    );
    final frames = _takeFrameSnapshot();
    final fields = <String, Object?>{
      'reason': reason,
      'lifecycle': _lifecycleState?.name ?? 'unknown',
      'frames': frames,
      'recent_session_count': _quality.length,
      'recent_sessions': _quality.entries
          .map((entry) => {
                'session_id': entry.key,
                'peer_id': entry.value.peerId,
                'age_seconds': now.difference(entry.value.updated).inSeconds,
                ...entry.value.values,
              })
          .toList(growable: false),
      'open_mobile_session_count': _mobileSessions.length,
      'selected_mobile_session_count':
          _mobileSessions.values.where((session) => session.active).length,
      'inactive_mobile_session_count':
          _mobileSessions.values.where((session) => !session.active).length,
      'mobile_sessions': _mobileSessions.entries.map((entry) {
        final quality = _quality[entry.key];
        final session = entry.value;
        return <String, Object?>{
          'session_id': entry.key,
          'peer_id': session.peerId,
          'active': session.active,
          'transport': session.direct == null
              ? 'unknown'
              : (session.direct! ? 'p2p' : 'relay'),
          'stream_type': session.streamType,
          'quality_age_seconds': quality == null
              ? null
              : now.difference(quality.updated).inSeconds,
          if (quality != null) ...quality.values,
        };
      }).toList(growable: false),
    };
    if (isAndroid) {
      try {
        final sample = await platformFFI.invokeMethod('get_power_profile_sample');
        if (sample is Map) {
          fields['android'] = Map<String, Object?>.from(sample);
        }
      } catch (error) {
        fields['android_sample_error'] = error.runtimeType.toString();
      }
    }
    try {
      await bind.mainWriteDiagnosticEvent(
        event: 'power_profile.flutter_sample',
        fieldsJson: jsonEncode(fields),
      );
    } catch (_) {
      // Profiling must never alter connection or rendering behavior.
    }
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      final total = timing.totalSpan.inMicroseconds;
      _frameCount += 1;
      _buildMicros += build;
      _rasterMicros += raster;
      if (total > _worstFrameMicros) _worstFrameMicros = total;
      if (total > 16667) _over16ms += 1;
      if (total > 33333) _over33ms += 1;
    }
  }

  void _setCachedEnabled(bool value) {
    _enabled = value;
    if (value && !_frameCallbackInstalled) {
      SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
      _frameCallbackInstalled = true;
    } else if (!value && _frameCallbackInstalled) {
      SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
      _frameCallbackInstalled = false;
      _resetFrames();
    }
  }

  Map<String, Object> _takeFrameSnapshot() {
    final count = _frameCount;
    final snapshot = <String, Object>{
      'count': count,
      'average_build_micros': count == 0 ? 0 : _buildMicros ~/ count,
      'average_raster_micros': count == 0 ? 0 : _rasterMicros ~/ count,
      'worst_total_micros': _worstFrameMicros,
      'over_16ms': _over16ms,
      'over_33ms': _over33ms,
    };
    _resetFrames();
    return snapshot;
  }

  void _resetFrames() {
    _frameCount = 0;
    _buildMicros = 0;
    _rasterMicros = 0;
    _worstFrameMicros = 0;
    _over16ms = 0;
    _over33ms = 0;
  }
}

class _QualitySnapshot {
  const _QualitySnapshot(this.peerId, this.updated, this.values);

  final String peerId;
  final DateTime updated;
  final Map<String, Object?> values;
}

class _MobileSessionSnapshot {
  _MobileSessionSnapshot(this.peerId, this.active);

  final String peerId;
  bool active;
  bool? direct;
  String streamType = '';
}
