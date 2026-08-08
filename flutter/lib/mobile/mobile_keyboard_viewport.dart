class MobileKeyboardViewportGuard {
  MobileKeyboardViewportGuard({
    required this.onAdjust,
    required this.onRefresh,
    required this.onRestore,
  });

  final void Function() onAdjust;
  final void Function() onRefresh;
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

  /// Recomputes the adjusted viewport after keyboard-adjacent controls finish
  /// laying out. The keyboard toolbar is measured after the first keyboard
  /// frame, so its final geometry cannot be part of the initial adjustment.
  void refreshLayout() {
    if (!_adjusted) return;
    onRefresh();
  }

  void dispose() {
    if (!_adjusted) return;
    _adjusted = false;
    onRestore();
  }
}
