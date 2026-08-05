import 'package:flutter_hbb/mobile/mobile_keyboard_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adjusts once for an active remote keyboard and restores on hide', () {
    final events = <String>[];
    final guard = MobileKeyboardViewportGuard(
      onAdjust: () => events.add('adjust'),
      onRestore: () => events.add('restore'),
    );

    guard.update(
      keyboardVisible: true,
      remoteEditorVisible: true,
      sessionActive: true,
    );
    guard.update(
      keyboardVisible: true,
      remoteEditorVisible: true,
      sessionActive: true,
    );
    guard.update(
      keyboardVisible: false,
      remoteEditorVisible: false,
      sessionActive: true,
    );

    expect(events, ['adjust', 'restore']);
  });

  test('ignores keyboards outside the active remote editor', () {
    final events = <String>[];
    final guard = MobileKeyboardViewportGuard(
      onAdjust: () => events.add('adjust'),
      onRestore: () => events.add('restore'),
    );

    guard.update(
      keyboardVisible: true,
      remoteEditorVisible: false,
      sessionActive: true,
    );
    guard.update(
      keyboardVisible: true,
      remoteEditorVisible: true,
      sessionActive: false,
    );

    expect(events, isEmpty);
  });

  test('restores an adjusted canvas when its tab becomes inactive', () {
    final events = <String>[];
    final guard = MobileKeyboardViewportGuard(
      onAdjust: () => events.add('adjust'),
      onRestore: () => events.add('restore'),
    );

    guard.update(
      keyboardVisible: true,
      remoteEditorVisible: true,
      sessionActive: true,
    );
    guard.update(
      keyboardVisible: true,
      remoteEditorVisible: true,
      sessionActive: false,
    );

    expect(events, ['adjust', 'restore']);
  });
}
