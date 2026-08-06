import 'dart:math';

class MobileMousePanAxisPlan {
  const MobileMousePanAxisPlan({
    required this.pointerDelta,
    required this.canvasDelta,
  });

  /// Pointer movement to attempt in remote-display coordinates.
  final double pointerDelta;

  /// Remote-display distance that the canvas must consume independently of
  /// whether the remote pointer is already clamped at the display edge.
  final double canvasDelta;
}

/// Plans one axis of RustDesk's mobile mouse-mode cursor-led panning.
///
/// Once the pointer crosses the visible midpoint, dragging should reveal the
/// hidden part of the canvas. The canvas delta deliberately remains separate
/// from the eventual clamped pointer delta: at a remote display edge the
/// pointer cannot move any farther, but the user's drag must still pan until
/// the corresponding canvas edge is visible.
MobileMousePanAxisPlan planMobileMousePanAxis({
  required double delta,
  required double pointerPosition,
  required double visibleStart,
  required double visibleEnd,
  required double displayStart,
  required double displayEnd,
}) {
  final visibleCenter = (visibleStart + visibleEnd) / 2;

  if (delta > 0) {
    final remainingCanvas = displayEnd - visibleEnd.roundToDouble();
    final movesCanvas =
        pointerPosition + delta > visibleCenter && remainingCanvas > 0;
    if (movesCanvas) {
      final bounded = min(delta, remainingCanvas);
      return MobileMousePanAxisPlan(
        pointerDelta: bounded,
        canvasDelta: bounded,
      );
    }
    return MobileMousePanAxisPlan(
      pointerDelta: min(delta, visibleEnd - pointerPosition),
      canvasDelta: 0,
    );
  }

  if (delta < 0) {
    final remainingCanvas = displayStart - visibleStart.roundToDouble();
    final movesCanvas =
        pointerPosition + delta < visibleCenter && remainingCanvas < 0;
    if (movesCanvas) {
      final bounded = max(delta, remainingCanvas);
      return MobileMousePanAxisPlan(
        pointerDelta: bounded,
        canvasDelta: bounded,
      );
    }
    return MobileMousePanAxisPlan(
      pointerDelta: max(delta, visibleStart - pointerPosition),
      canvasDelta: 0,
    );
  }

  return const MobileMousePanAxisPlan(pointerDelta: 0, canvasDelta: 0);
}
