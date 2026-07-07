/// Official update URLs are unsafe for a fork whose protocol and signing identity
/// intentionally differ from upstream. Custom clients already opt out through the
/// stock flag; the build identity covers this source-built ICE fork as well.
bool shouldCheckForSoftwareUpdates({
  required bool isCustomClient,
  required String buildIdentity,
}) {
  if (isCustomClient) {
    return false;
  }
  return !buildIdentity.toUpperCase().contains('UNOFFICIAL');
}
