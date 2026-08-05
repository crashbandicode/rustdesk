class MobileKeyboardViewportGuard {
  MobileKeyboardViewportGuard({
    required this.onAdjust,
    required this.onRestore,
  });

  final void Function() onAdjust;
  final void Function() onRestore;

  bool _adjusted = false;

  void update({
    required bool keyboardVisible,
    required bool remoteEditorVisible,
    required bool sessionActive,
  }) {
    final shouldAdjust =
        keyboardVisible && remoteEditorVisible && sessionActive;
    if (shouldAdjust == _adjusted) return;

    _adjusted = shouldAdjust;
    if (shouldAdjust) {
      onAdjust();
    } else {
      onRestore();
    }
  }

  void dispose() {
    if (!_adjusted) return;
    _adjusted = false;
    onRestore();
  }
}
