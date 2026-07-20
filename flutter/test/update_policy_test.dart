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

  test('resume update checks are allowed at a bounded cadence', () {
    final gate = SoftwareUpdateRefreshGate(
      minimumInterval: const Duration(minutes: 2),
    );

    expect(gate.shouldRequest(Duration.zero), isTrue);
    expect(
        gate.shouldRequest(const Duration(minutes: 1, seconds: 59)), isFalse);
    expect(gate.shouldRequest(const Duration(minutes: 2)), isTrue);
    expect(gate.shouldRequest(const Duration(minutes: 3)), isFalse);
    expect(gate.shouldRequest(const Duration(minutes: 4)), isTrue);
  });

  test('a monotonic clock reset permits a fresh update request', () {
    final gate = SoftwareUpdateRefreshGate(
      minimumInterval: const Duration(minutes: 2),
    );

    expect(gate.shouldRequest(const Duration(minutes: 10)), isTrue);
    expect(gate.shouldRequest(const Duration(minutes: 1)), isTrue);
  });

  test('the same release does not automatically reopen the installer', () {
    const release =
        'https://github.com/crashbandicode/rustdesk/releases/tag/1.4.9-69';
    expect(
      newGithubForkAndroidApkUrl(
        previousReleasePageUrl: release,
        releasePageUrl: release,
      ),
      isNull,
    );
    expect(
      newGithubForkAndroidApkUrl(
        previousReleasePageUrl: '',
        releasePageUrl: release,
      ),
      'https://github.com/crashbandicode/rustdesk/releases/download/1.4.9-69/rustdesk-1.4.9-69-aarch64.apk',
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
