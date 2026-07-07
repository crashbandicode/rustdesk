import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/keyboard_image_paste.dart';
import 'package:image/image.dart' as image_codec;

void main() {
  test('keeps PNG keyboard content as PNG', () {
    final source = Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3]);
    final result = normalizeKeyboardImageToPng(
      (bytes: source, mimeType: 'image/png'),
    );

    expect(result, source);
    expect(identical(result, source), isFalse);
  });

  test('transcodes JPEG keyboard content to a valid PNG', () {
    final image = image_codec.Image(width: 2, height: 1);
    image.setPixelRgba(0, 0, 255, 0, 0, 255);
    image.setPixelRgba(1, 0, 0, 255, 0, 255);
    final jpeg = Uint8List.fromList(image_codec.encodeJpg(image));

    final result = normalizeKeyboardImageToPng(
      (bytes: jpeg, mimeType: 'image/jpeg'),
    );

    expect(result, isNotNull);
    expect(result!.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    expect(image_codec.decodePng(result), isNotNull);
  });

  test('rejects empty or oversized keyboard content', () {
    expect(
      normalizeKeyboardImageToPng(
        (bytes: Uint8List(0), mimeType: 'image/png'),
      ),
      isNull,
    );
    expect(
      normalizeKeyboardImageToPng(
        (bytes: Uint8List(kMaxKeyboardImageBytes + 1), mimeType: 'image/png'),
      ),
      isNull,
    );
  });
}
