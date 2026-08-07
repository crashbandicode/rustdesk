typedef MobilePeerLabelData = ({
  String id,
  String alias,
  String hostname,
  String username,
});

/// Human-friendly label for a peer, ordered by the address-book fields users
/// are most likely to recognize.
String mobilePeerDisplayName(MobilePeerLabelData peer) {
  if (peer.alias.isNotEmpty) return peer.alias;
  if (peer.hostname.isNotEmpty) return peer.hostname;
  if (peer.username.isNotEmpty) return peer.username;
  return peer.id;
}

/// Resolve a connected peer through every loaded address book. When the same
/// ID exists in multiple books, prefer the entry with the strongest name.
String mobileAddressBookPeerLabel(
  String peerId,
  Iterable<MobilePeerLabelData> peers,
) {
  MobilePeerLabelData? best;
  var bestScore = -1;
  for (final peer in peers) {
    if (peer.id != peerId) continue;
    final score = peer.alias.isNotEmpty
        ? 3
        : peer.hostname.isNotEmpty
            ? 2
            : peer.username.isNotEmpty
                ? 1
                : 0;
    if (score > bestScore) {
      best = peer;
      bestScore = score;
    }
  }
  return best == null ? peerId : mobilePeerDisplayName(best);
}
