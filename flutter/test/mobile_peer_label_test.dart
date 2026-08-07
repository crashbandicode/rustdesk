import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/mobile_peer_label.dart';

void main() {
  test('uses an address-book alias instead of the connected peer ID', () {
    final peers = [
      (
        id: '1990796488',
        alias: 'Yoga',
        hostname: '',
        username: '',
      ),
    ];

    expect(
      mobileAddressBookPeerLabel('1990796488', peers),
      'Yoga',
    );
  });

  test('falls back to hostname and then the peer ID', () {
    final peers = [
      (
        id: '501896904',
        alias: '',
        hostname: 'Desktop',
        username: '',
      ),
    ];

    expect(
      mobileAddressBookPeerLabel('501896904', peers),
      'Desktop',
    );
    expect(
      mobileAddressBookPeerLabel('missing', peers),
      'missing',
    );
  });

  test('prefers an alias from another address book over a weaker label', () {
    final peers = [
      (
        id: '1990796488',
        alias: '',
        hostname: 'YOGA-LAPTOP',
        username: '',
      ),
      (
        id: '1990796488',
        alias: 'Yoga VPN',
        hostname: '',
        username: '',
      ),
    ];

    expect(
      mobileAddressBookPeerLabel('1990796488', peers),
      'Yoga VPN',
    );
  });
}
