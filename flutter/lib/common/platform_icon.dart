/// Resolve a peer platform to the bundled icon asset name.
///
/// Account/device APIs may legitimately return a partial peer record before
/// the client has connected to it. Use an honest generic device glyph for an
/// absent or unknown platform instead of rendering an empty colored tile.
String peerPlatformIconAsset(String platform) {
  final normalized = platform.trim().toLowerCase();
  if (normalized.isEmpty) {
    return 'screen';
  }
  if (normalized == 'mac os' ||
      normalized == 'mac' ||
      normalized == 'macos' ||
      normalized.contains('darwin')) {
    return 'mac';
  }
  if (normalized.contains('linux')) {
    return 'linux';
  }
  if (normalized.contains('android')) {
    return 'android';
  }
  if (normalized == 'webdesktop' ||
      normalized == 'win' ||
      normalized.contains('windows')) {
    return 'win';
  }
  return 'screen';
}
