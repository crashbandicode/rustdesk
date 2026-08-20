import 'package:flutter_hbb/common/platform_icon.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

Peer peer({
  required String id,
  String platform = '',
  String hostname = '',
  String username = '',
  String alias = '',
  String loginName = '',
  String password = '',
}) {
  return Peer(
    id: id,
    hash: '',
    password: password,
    username: username,
    hostname: hostname,
    platform: platform,
    alias: alias,
    tags: [],
    forceAlwaysRelay: false,
    rdpPort: '',
    rdpUsername: '',
    loginName: loginName,
    device_group_name: '',
    note: '',
  );
}

void main() {
  test('partial accessible peer merges address book and recent identity', () {
    final accessible = peer(id: '1990796488');
    final changed = mergeMissingPeerDisplayMetadata(accessible, [
      peer(id: '1990796488', alias: 'dreamland-yoga'),
      peer(
        id: '1990796488',
        platform: kPeerPlatformWindows,
        hostname: 'dreamland-yoga',
        username: 'intpa',
      ),
    ]);

    expect(changed, isTrue);
    expect(accessible.platform, kPeerPlatformWindows);
    expect(accessible.alias, 'dreamland-yoga');
    expect(accessible.hostname, 'dreamland-yoga');
    expect(accessible.username, 'intpa');
  });

  test('server values remain authoritative and secrets are never merged', () {
    final accessible = peer(
      id: '501896904',
      platform: kPeerPlatformWindows,
      hostname: 'api-host',
      password: 'api-secret',
    );
    final changed = mergeMissingPeerDisplayMetadata(accessible, [
      peer(
        id: '501896904',
        platform: kPeerPlatformMacOS,
        hostname: 'cached-host',
        alias: 'butterbridge-surface',
        password: 'cached-secret',
      ),
      peer(id: 'other', alias: 'wrong-peer'),
    ]);

    expect(changed, isTrue);
    expect(accessible.platform, kPeerPlatformWindows);
    expect(accessible.hostname, 'api-host');
    expect(accessible.alias, 'butterbridge-surface');
    expect(accessible.password, 'api-secret');
  });

  test('platform icon mapping is deterministic with an honest fallback', () {
    expect(peerPlatformIconAsset(kPeerPlatformWindows), 'win');
    expect(peerPlatformIconAsset('windows / Windows 11 Pro'), 'win');
    expect(peerPlatformIconAsset(kPeerPlatformMacOS), 'mac');
    expect(peerPlatformIconAsset('Darwin'), 'mac');
    expect(peerPlatformIconAsset(kPeerPlatformLinux), 'linux');
    expect(peerPlatformIconAsset(kPeerPlatformAndroid), 'android');
    expect(peerPlatformIconAsset(''), 'screen');
    expect(peerPlatformIconAsset('FreeBSD'), 'screen');
  });
}
