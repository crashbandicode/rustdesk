const Duration kTransientNetworkReconnectWindow = Duration(minutes: 2);
const int kMaxTransientNetworkReconnectDelaySeconds = 8;

/// Returns true for transport failures that commonly occur while Android is
/// backgrounded or while its network/DNS service is being restored.
bool isTransientMobileNetworkError({
  required String type,
  required String title,
  required String text,
}) {
  if (type != 'error' || title != 'Connection Error') {
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
    'connection reset by peer',
    'broken pipe',
  ].any(message.contains);
}

String connectionTransportLabel(bool direct) =>
    direct ? 'Connected peer-to-peer' : 'Connected over relay';
