import 'package:flutter/services.dart';

/// A remote edit derived from the Android IME's latest editing value.
class AndroidImeEditPlan {
  const AndroidImeEditPlan({
    required this.deleteCount,
    required this.insertText,
    required this.nextSentValue,
    required this.deferred,
  });

  const AndroidImeEditPlan.deferred(String sentValue)
      : deleteCount = 0,
        insertText = '',
        nextSentValue = sentValue,
        deferred = true;

  final int deleteCount;
  final String insertText;
  final String nextSentValue;
  final bool deferred;

  bool get hasRemoteEdit => deleteCount != 0 || insertText.isNotEmpty;
}

/// Plans an edit against the value that has actually been sent to the peer.
///
/// Android IMEs use a composing range for provisional text, including Gboard
/// voice typing. Append-only composition is safe to stream immediately. A
/// rewrite or deletion inside the composing range is held until the IME commits
/// it, preserving the suggestion/composition session while still allowing live
/// dictation and ordinary typing to reach the peer.
AndroidImeEditPlan planAndroidImeEdit({
  required String sentValue,
  required TextEditingValue editingValue,
}) {
  final newValue = editingValue.text;
  var diffBase = sentValue;

  if (diffBase.isNotEmpty &&
      newValue.isNotEmpty &&
      diffBase[0] == '1' &&
      newValue[0] != '1') {
    // Some IMEs replace the hidden backspace-reservoir text when inserting
    // clipboard or dictated content. The reservoir was never sent remotely.
    diffBase = '';
  }

  var common = 0;
  while (common < diffBase.length &&
      common < newValue.length &&
      diffBase[common] == newValue[common]) {
    common++;
  }

  final isComposing =
      editingValue.isComposingRangeValid && !editingValue.composing.isCollapsed;
  final rewritesSentText = common < diffBase.length;
  if (isComposing && rewritesSentText) {
    return AndroidImeEditPlan.deferred(sentValue);
  }

  return AndroidImeEditPlan(
    deleteCount: diffBase.length - common,
    insertText: newValue.substring(common),
    nextSentValue: newValue,
    deferred: false,
  );
}
