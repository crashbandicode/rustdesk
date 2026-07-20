import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/pressed_key_tracker.dart';

class _KeyRecord {
  const _KeyRecord(this.physicalKey, this.logicalKey);

  final PhysicalKeyboardKey physicalKey;
  final LogicalKeyboardKey logicalKey;
}

void main() {
  late PressedKeyTracker<_KeyRecord> tracker;

  setUp(() {
    tracker = PressedKeyTracker<_KeyRecord>(
      physicalKeyOf: (event) => event.physicalKey,
      logicalKeyOf: (event) => event.logicalKey,
    );
  });

  test('matching key up removes a held key', () {
    tracker.keyDown(const _KeyRecord(
      PhysicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyA,
    ));
    tracker.keyUp(PhysicalKeyboardKey.keyA);

    expect(tracker.count, 0);
    expect(tracker.takeForRelease(), isEmpty);
  });

  test('ordinary keys release before shortcut modifiers', () {
    const ctrl = _KeyRecord(
      PhysicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlLeft,
    );
    const shift = _KeyRecord(
      PhysicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftLeft,
    );
    const a = _KeyRecord(
      PhysicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyA,
    );
    tracker
      ..keyDown(ctrl)
      ..keyDown(shift)
      ..keyDown(a);

    expect(tracker.takeForRelease(), [a, ctrl, shift]);
    expect(tracker.count, 0);
  });

  test('repeated down replaces rather than duplicates a key', () {
    const first = _KeyRecord(
      PhysicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyA,
    );
    const repeat = _KeyRecord(
      PhysicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyA,
    );
    tracker
      ..keyDown(first)
      ..keyDown(repeat);

    expect(tracker.count, 1);
    expect(tracker.takeForRelease(), [repeat]);
  });
}
