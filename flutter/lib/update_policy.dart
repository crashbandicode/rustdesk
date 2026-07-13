const String _githubForkBuildPrefix = 'crashbandicode/rustdesk';
const String _githubForkReleasePrefix =
    'https://github.com/crashbandicode/rustdesk/releases/tag/';
const String _githubForkDownloadPrefix =
    'https://github.com/crashbandicode/rustdesk/releases/download/';

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
