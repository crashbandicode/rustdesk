import '../common.dart';
import '../consts.dart';
import '../diagnostics.dart';
import '../models/platform_model.dart';
import 'outgoing_session_keepalive_state.dart';

bool mobileOutgoingSessionKeepaliveEnabled() =>
    mobileOutgoingSessionKeepaliveEnabledFromOption(
      bind.mainGetLocalOption(key: kOptionAllowBackgroundSessionKeepalive),
    );

final mobileOutgoingSessionKeepalive =
    MobileOutgoingSessionKeepaliveCoordinator(
      isEnabled: mobileOutgoingSessionKeepaliveEnabled,
      publish: _publishMobileOutgoingSessionKeepalive,
    );

Future<void> setMobileOutgoingSessionKeepaliveEnabled(bool enabled) async {
  await bind.mainSetLocalOption(
    key: kOptionAllowBackgroundSessionKeepalive,
    value: enabled ? 'Y' : 'N',
  );
  await mobileOutgoingSessionKeepalive.refresh();
}

Future<void> _publishMobileOutgoingSessionKeepalive(
  MobileOutgoingSessionKeepaliveSnapshot snapshot,
) async {
  if (!isAndroid) return;
  try {
    await gFFI.invokeMethod(
      'set_outgoing_session_count',
      snapshot.effectiveSessionCount,
    );
    await DiagnosticSupport.event('mobile_outgoing_service_updated', {
      'session_count': snapshot.sessionCount,
      'effective_session_count': snapshot.effectiveSessionCount,
      'background_keepalive_enabled': snapshot.enabled,
    });
  } catch (error) {
    await DiagnosticSupport.event('mobile_outgoing_service_failed', {
      'session_count': snapshot.sessionCount,
      'effective_session_count': snapshot.effectiveSessionCount,
      'background_keepalive_enabled': snapshot.enabled,
      'error': error.toString(),
    });
  }
}
