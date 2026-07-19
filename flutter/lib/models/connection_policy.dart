const Duration kTransientNetworkReconnectWindow = Duration(minutes: 2);
const int kMaxTransientNetworkReconnectDelaySeconds = 8;
const Duration kTransientNetworkReconnectAttemptTimeout =
    Duration(seconds: 15);
const Duration kTransientNetworkFirstFrameTimeout = Duration(seconds: 8);
const Duration kMobileResumeFrameProbeTimeout = Duration(seconds: 3);

/// Returns true for transport failures that commonly occur while Android is
/// backgrounded or while its network/DNS service is being restored.
bool isTransientMobileNetworkError({
  required String type,
  required String title,
  required String text,
}) {
  final isConnectionError = type == 'error' && title == 'Connection Error';
  final isDirectConnectionHint =
      (type == 'relay-hint' || type == 'relay-hint2') &&
          title == 'Connection Error';
  if (!isConnectionError && !isDirectConnectionHint) {
    return false;
  }

  final message = text.toLowerCase();
  return const <String>[
    'failed to lookup address information',
    'no address associated with hostname',
    'temporary failure in name resolution',
    'name or service not known',
    'network is unreachable',
    'network unreachable',
    'software caused connection abort',
    'connection aborted',
    'connection reset by peer',
    'connection reset without closing handshake',
    'websocket protocol error',
    'unexpected eof',
    'broken pipe',
    'deadline has elapsed',
    'operation timed out',
    'connection timed out',
    'host is unreachable',
  ].any(message.contains);
}

/// Keeps the first direct-connect failure user-visible so relay remains an
/// explicit choice, but automatically repairs the same transient failure once
/// this session has previously established a working transport.
bool shouldAutoRecoverTransientMobileNetworkError({
  required String type,
  required String title,
  required String text,
  required bool hasEverConnected,
}) {
  if (!isTransientMobileNetworkError(
      type: type, title: title, text: text)) {
    return false;
  }
  final isDirectConnectionHint =
      type == 'relay-hint' || type == 'relay-hint2';
  return !isDirectConnectionHint || hasEverConnected;
}

String connectionTransportLabel(bool direct) =>
    direct ? 'Connected peer-to-peer' : 'Connected over relay';
