import 'package:flutter/services.dart';

bool isModifierLogicalKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.superKey;
}

/// Tracks physical key-down events until their matching key-up arrives.
///
/// Flutter can omit key-up events when focus or Android lifecycle ownership
/// changes. Release order deliberately puts ordinary keys before modifiers so
/// an abandoned shortcut cannot continue auto-repeating while its modifiers
/// are being unwound.
class PressedKeyTracker<T> {
  PressedKeyTracker({
    required this.physicalKeyOf,
    required this.logicalKeyOf,
  });

  final PhysicalKeyboardKey Function(T event) physicalKeyOf;
  final LogicalKeyboardKey Function(T event) logicalKeyOf;
  final Map<PhysicalKeyboardKey, T> _pressed = {};

  int get count => _pressed.length;

  void keyDown(T event) {
    _pressed[physicalKeyOf(event)] = event;
  }

  void keyUp(PhysicalKeyboardKey key) {
    _pressed.remove(key);
  }

  List<T> takeForRelease() {
    final events = _pressed.values.toList(growable: false);
    _pressed.clear();
    return [
      for (final event in events)
        if (!isModifierLogicalKey(logicalKeyOf(event))) event,
      for (final event in events)
        if (isModifierLogicalKey(logicalKeyOf(event))) event,
    ];
  }

  void reset() => _pressed.clear();
}
