const String _githubForkBuildPrefix = 'crashbandicode/rustdesk';
const String _githubForkReleasePrefix =
    'https://github.com/crashbandicode/rustdesk/releases/tag/';
const String _githubForkDownloadPrefix =
    'https://github.com/crashbandicode/rustdesk/releases/download/';

/// Bounds lifecycle-triggered update checks without relying on wall-clock time.
///
/// Callers pass a monotonic elapsed duration (normally from [Stopwatch]) so a
/// device clock correction cannot suppress checks indefinitely or cause a
/// burst of duplicate requests.
class SoftwareUpdateRefreshGate {
  SoftwareUpdateRefreshGate({required this.minimumInterval});

  final Duration minimumInterval;
  Duration? _lastRequestAt;

  bool shouldRequest(Duration elapsed) {
    final lastRequestAt = _lastRequestAt;
    if (lastRequestAt != null) {
      final elapsedSinceRequest = elapsed - lastRequestAt;
      if (!elapsedSinceRequest.isNegative &&
          elapsedSinceRequest < minimumInterval) {
        return false;
      }
    }
    _lastRequestAt = elapsed;
    return true;
  }
}

/// Returns whether this is the signed custom build that publishes updates from
/// the fork's GitHub Releases channel.
bool isGitHubForkBuildIdentity(String buildIdentity) =>
    buildIdentity == _githubForkBuildPrefix ||
    buildIdentity.startsWith('$_githubForkBuildPrefix ');

/// Builds the matching signed Android asset URL from a validated release page.
///
/// Keep this strict: only our own release page and the numeric patch-version
/// scheme emitted by CI are eligible for automatic downloads.
String? githubForkAndroidApkUrl(String releasePageUrl) {
  if (!releasePageUrl.startsWith(_githubForkReleasePrefix)) return null;
  final tag = releasePageUrl.substring(_githubForkReleasePrefix.length);
  if (!RegExp(r'^\d+\.\d+\.\d+-\d+$').hasMatch(tag)) return null;
  return '$_githubForkDownloadPrefix$tag/rustdesk-$tag-aarch64.apk';
}

/// Returns an APK only when the update event identifies a different release.
///
/// Resume checks can emit the same URL repeatedly. Treating those as a new
/// automatic install would reopen Android's package installer every cooldown;
/// the visible banner remains available for an explicit retry instead.
String? newGithubForkAndroidApkUrl({
  required String previousReleasePageUrl,
  required String releasePageUrl,
}) {
  if (releasePageUrl == previousReleasePageUrl) return null;
  return githubForkAndroidApkUrl(releasePageUrl);
}

/// Official update URLs are unsafe for arbitrary custom clients whose protocol
/// and signing identity differ from upstream. This signed fork is the explicit
/// exception: it checks only its own GitHub Releases channel.
bool shouldCheckForSoftwareUpdates({
  required bool isCustomClient,
  required String buildIdentity,
}) {
  if (isGitHubForkBuildIdentity(buildIdentity)) {
    return true;
  }
  if (isCustomClient) {
    return false;
  }
  return !buildIdentity.toUpperCase().contains('UNOFFICIAL');
}
