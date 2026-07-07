import 'dart:typed_data';

import 'package:image/image.dart' as image_codec;

const int kMaxKeyboardImageBytes = 16 * 1024 * 1024;

typedef KeyboardImagePayload = ({Uint8List bytes, String mimeType});

/// Converts rich content committed by an Android IME to the PNG clipboard
/// format understood by RustDesk peers. Animated formats intentionally use the
/// first decoded frame because desktop image clipboards are static.
Uint8List? normalizeKeyboardImageToPng(KeyboardImagePayload payload) {
  final bytes = payload.bytes;
  if (bytes.isEmpty || bytes.length > kMaxKeyboardImageBytes) {
    return null;
  }

  if (payload.mimeType.toLowerCase() == 'image/png') {
    return Uint8List.fromList(bytes);
  }

  final decoded = image_codec.decodeImage(bytes);
  if (decoded == null) {
    return null;
  }
  final png = image_codec.encodePng(decoded);
  if (png.isEmpty || png.length > kMaxKeyboardImageBytes) {
    return null;
  }
  return Uint8List.fromList(png);
}
