import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/native_android_ime.dart';

void main() {
  test('parses native editing state including composing range', () {
    final value = parseNativeAndroidEditingValue({
      'text': 'hello',
      'selectionBase': 5,
      'selectionExtent': 5,
      'composingBase': 1,
      'composingExtent': 5,
    });

    expect(value?.text, 'hello');
    expect(value?.selection, const TextSelection.collapsed(offset: 5));
    expect(value?.composing, const TextRange(start: 1, end: 5));
  });

  test('clamps selection and rejects invalid composing range', () {
    final value = parseNativeAndroidEditingValue({
      'text': 'abc',
      'selectionBase': 99,
      'selectionExtent': -5,
      'composingBase': 2,
      'composingExtent': 9,
    });

    expect(value?.selection.baseOffset, 3);
    expect(value?.selection.extentOffset, 0);
    expect(value?.composing, TextRange.empty);
  });

  test('rejects malformed native editing state', () {
    expect(parseNativeAndroidEditingValue(null), isNull);
    expect(parseNativeAndroidEditingValue({'text': 42}), isNull);
  });
}
