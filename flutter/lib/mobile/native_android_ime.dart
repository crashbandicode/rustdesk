import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'keyboard_image_paste.dart';

const String _nativeImeViewType = 'rustdesk/remote-ime';

/// Controls the lifecycle-independent commands for the native Android editor.
/// A pending show request is replayed when Android finishes creating the platform view.
class NativeAndroidImeController {
  MethodChannel? _channel;
  bool _showWhenReady = false;

  void attach(MethodChannel channel) {
    _channel = channel;
    if (_showWhenReady) {
      unawaited(channel.invokeMethod<void>('show'));
    }
  }

  void detach(MethodChannel channel) {
    if (identical(_channel, channel)) {
      _channel = null;
    }
  }

  void show() {
    _showWhenReady = true;
    final channel = _channel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('show'));
    }
  }

  void hide() {
    _showWhenReady = false;
    final channel = _channel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('hide'));
    }
  }

  void reset() {
    _showWhenReady = false;
    _channel = null;
  }
}

class NativeAndroidIme extends StatefulWidget {
  const NativeAndroidIme({
    super.key,
    required this.controller,
    required this.initialText,
    required this.onEditingValueChanged,
    required this.onImageContent,
    required this.onImageError,
  });

  final NativeAndroidImeController controller;
  final String initialText;
  final ValueChanged<TextEditingValue> onEditingValueChanged;
  final ValueChanged<KeyboardImagePayload> onImageContent;
  final ValueChanged<String> onImageError;

  @override
  State<NativeAndroidIme> createState() => _NativeAndroidImeState();
}

class _NativeAndroidImeState extends State<NativeAndroidIme> {
  MethodChannel? _channel;
  final RecentKeyboardImageDeduplicator _imageDeduplicator =
      RecentKeyboardImageDeduplicator();

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) {
      channel.setMethodCallHandler(null);
      widget.controller.detach(channel);
    }
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('$_nativeImeViewType/$viewId');
    _channel = channel;
    channel.setMethodCallHandler(_handleNativeCall);
    widget.controller.attach(channel);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'editing_state':
        final value = parseNativeAndroidEditingValue(call.arguments);
        if (value != null) {
          widget.onEditingValueChanged(value);
        }
        break;
      case 'image_content':
        final payload = parseAndroidImagePayload(call.arguments);
        if (payload != null) {
          if (_imageDeduplicator.shouldAccept(payload)) {
            widget.onImageContent(payload);
          }
        } else {
          widget.onImageError('The keyboard provided invalid image data');
        }
        break;
      case 'image_error':
        final arguments = call.arguments;
        final message = arguments is Map ? arguments['message'] : null;
        widget.onImageError(message is String
            ? message
            : 'Unable to read image content from the keyboard');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1,
      height: 1,
      child: AndroidView(
        viewType: _nativeImeViewType,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        creationParams: <String, Object?>{'initialText': widget.initialText},
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      ),
    );
  }
}

/// Some Gboard/Android combinations dispatch the same committed content through
/// both receive-content and InputConnection compatibility paths. Suppress only
/// byte-identical events inside a short window so one user action causes one
/// remote paste while a deliberate second paste still works.
class RecentKeyboardImageDeduplicator {
  RecentKeyboardImageDeduplicator({
    this.window = const Duration(milliseconds: 1500),
  });

  final Duration window;
  int? _lastFingerprint;
  DateTime? _lastAcceptedAt;

  bool shouldAccept(KeyboardImagePayload payload, {DateTime? now}) {
    now ??= DateTime.now();
    final fingerprint = keyboardImagePayloadFingerprint(payload);
    final duplicate = _lastFingerprint == fingerprint &&
        _lastAcceptedAt != null &&
        now.difference(_lastAcceptedAt!) < window;
    if (duplicate) {
      return false;
    }
    _lastFingerprint = fingerprint;
    _lastAcceptedAt = now;
    return true;
  }
}

/// A bounded-cost content fingerprint. At most ~4K bytes are sampled so a large
/// screenshot cannot stall the UI thread while duplicate rich-content callbacks
/// remain extremely unlikely to collide inside the 1.5-second guard window.
int keyboardImagePayloadFingerprint(KeyboardImagePayload payload) {
  final bytes = payload.bytes;
  final stride = bytes.length <= 4096 ? 1 : (bytes.length ~/ 4096);
  var hash = 0x811c9dc5;
  for (var i = 0; i < bytes.length; i += stride) {
    hash = ((hash ^ bytes[i]) * 16777619) & 0x3fffffff;
  }
  if (bytes.isNotEmpty) {
    hash = ((hash ^ bytes.last) * 16777619) & 0x3fffffff;
  }
  return Object.hash(payload.mimeType.toLowerCase(), bytes.length, hash);
}

TextEditingValue? parseNativeAndroidEditingValue(dynamic payload) {
  if (payload is! Map || payload['text'] is! String) {
    return null;
  }
  final text = payload['text'] as String;
  int validOffset(dynamic value, int fallback) {
    if (value is! int) return fallback;
    return value.clamp(0, text.length);
  }

  final selectionBase = validOffset(payload['selectionBase'], text.length);
  final selectionExtent =
      validOffset(payload['selectionExtent'], selectionBase);
  final composingBase = payload['composingBase'];
  final composingExtent = payload['composingExtent'];
  final composing = composingBase is int &&
          composingExtent is int &&
          composingBase >= 0 &&
          composingExtent >= composingBase &&
          composingExtent <= text.length
      ? TextRange(start: composingBase, end: composingExtent)
      : TextRange.empty;

  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: selectionBase,
      extentOffset: selectionExtent,
    ),
    composing: composing,
  );
}
