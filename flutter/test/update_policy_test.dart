import 'package:flutter_hbb/update_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unofficial fork does not advertise official upgrades', () {
    expect(
      shouldCheckForSoftwareUpdates(
        isCustomClient: false,
        buildIdentity:
            'crashbandicode/rustdesk ICE fork (UNOFFICIAL) · commit 01fa3ac',
      ),
      isFalse,
    );
  });

  test('stock custom clients and official builds retain their policies', () {
    expect(
      shouldCheckForSoftwareUpdates(
        isCustomClient: true,
        buildIdentity: 'Official custom client',
      ),
      isFalse,
    );
    expect(
      shouldCheckForSoftwareUpdates(
        isCustomClient: false,
        buildIdentity: 'RustDesk 1.4.9',
      ),
      isTrue,
    );
  });
}
