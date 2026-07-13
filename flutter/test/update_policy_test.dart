import 'package:flutter_hbb/update_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unofficial fork uses its dedicated release channel', () {
    expect(
      shouldCheckForSoftwareUpdates(
        isCustomClient: false,
        buildIdentity:
            'crashbandicode/rustdesk ICE fork (UNOFFICIAL) · commit 01fa3ac',
      ),
      isTrue,
    );
    expect(
      isGitHubForkBuildIdentity('crashbandicode/rustdesk-malicious'),
      isFalse,
    );
  });

  test('fork Android downloads require an exact numeric release URL', () {
    expect(
      githubForkAndroidApkUrl(
          'https://github.com/crashbandicode/rustdesk/releases/tag/1.4.9-56'),
      'https://github.com/crashbandicode/rustdesk/releases/download/1.4.9-56/rustdesk-1.4.9-56-aarch64.apk',
    );
    expect(
      githubForkAndroidApkUrl(
          'https://github.com/attacker/rustdesk/releases/tag/1.4.9-56'),
      isNull,
    );
    expect(
      githubForkAndroidApkUrl(
          'https://github.com/crashbandicode/rustdesk/releases/tag/latest'),
      isNull,
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
