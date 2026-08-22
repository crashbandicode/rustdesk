import 'package:flutter_hbb/common/remembered_display.dart';
import 'package:flutter_test/flutter_test.dart';

const allDisplays = -1;

const left = RemoteDisplayIdentity(
  name: r'\\.\DISPLAY1',
  x: 0,
  y: 0,
  width: 1920,
  height: 1080,
);
const right = RemoteDisplayIdentity(
  name: r'\\.\DISPLAY2',
  x: 1920,
  y: 0,
  width: 2560,
  height: 1440,
);

void main() {
  test('round trips a remembered display', () {
    const remembered = RememberedRemoteDisplay(index: 1, identity: right);
    final decoded = RememberedRemoteDisplay.decode(remembered.encode());

    expect(decoded, isNotNull);
    expect(decoded!.index, 1);
    expect(decoded.identity!.name, right.name);
    expect(decoded.identity!.width, right.width);
  });

  test('restores a named display after monitor order changes', () {
    const remembered = RememberedRemoteDisplay(index: 1, identity: right);

    expect(
      resolveRememberedRemoteDisplay(
        remembered,
        const [right, left],
        allDisplaysValue: allDisplays,
      ),
      0,
    );
  });

  test('does not redirect a removed named monitor to its old index', () {
    const remembered = RememberedRemoteDisplay(index: 1, identity: right);

    expect(
      resolveRememberedRemoteDisplay(
        remembered,
        const [left],
        allDisplaysValue: allDisplays,
      ),
      isNull,
    );
  });

  test('uses geometry and then index for peers without display names', () {
    const unnamedRight = RemoteDisplayIdentity(
      name: '',
      x: 1920,
      y: 0,
      width: 2560,
      height: 1440,
    );
    const remembered =
        RememberedRemoteDisplay(index: 1, identity: unnamedRight);

    expect(
      resolveRememberedRemoteDisplay(
        remembered,
        const [unnamedRight, left],
        allDisplaysValue: allDisplays,
      ),
      0,
    );
    expect(
      resolveRememberedRemoteDisplay(
        const RememberedRemoteDisplay(index: 1),
        const [left, right],
        allDisplaysValue: allDisplays,
      ),
      1,
    );
  });

  test('restores all-displays only when a display still exists', () {
    expect(
      resolveRememberedRemoteDisplay(
        const RememberedRemoteDisplay(index: allDisplays),
        const [left, right],
        allDisplaysValue: allDisplays,
      ),
      allDisplays,
    );
    expect(
      resolveRememberedRemoteDisplay(
        const RememberedRemoteDisplay(index: allDisplays),
        const [],
        allDisplaysValue: allDisplays,
      ),
      isNull,
    );
  });

  test('rejects malformed persisted state', () {
    expect(RememberedRemoteDisplay.decode('not json'), isNull);
    expect(RememberedRemoteDisplay.decode('{"version":2,"index":0}'), isNull);
    expect(RememberedRemoteDisplay.decode('{"version":1,"index":"0"}'), isNull);
  });
}
