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

  test('suppresses a duplicate rich-image callback inside the guard window',
      () {
    final deduplicator = RecentKeyboardImageDeduplicator();
    final payload = (
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      mimeType: 'image/png',
    );
    final started = DateTime(2026, 7, 7, 12);

    expect(deduplicator.shouldAccept(payload, now: started), isTrue);
    expect(
      deduplicator.shouldAccept(
        payload,
        now: started.add(const Duration(milliseconds: 500)),
      ),
      isFalse,
    );
    expect(
      deduplicator.shouldAccept(
        payload,
        now: started.add(const Duration(seconds: 2)),
      ),
      isTrue,
    );
  });

  test('does not suppress different rich-image content', () {
    final deduplicator = RecentKeyboardImageDeduplicator();
    final now = DateTime(2026, 7, 7, 12);

    expect(
      deduplicator.shouldAccept(
        (bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png'),
        now: now,
      ),
      isTrue,
    );
    expect(
      deduplicator.shouldAccept(
        (bytes: Uint8List.fromList([1, 2, 4]), mimeType: 'image/png'),
        now: now.add(const Duration(milliseconds: 100)),
      ),
      isTrue,
    );
  });
}
