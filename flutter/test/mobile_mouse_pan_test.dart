import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/mobile_mouse_pan.dart';

void main() {
  group('mobile mouse-mode canvas pan planning', () {
    test('keeps consuming drag after the remote pointer reaches an edge', () {
      final plan = planMobileMousePanAxis(
        delta: 32,
        pointerPosition: 1080,
        visibleStart: 200,
        visibleEnd: 700,
        displayStart: 0,
        displayEnd: 1080,
      );

      expect(plan.pointerDelta, 32);
      expect(plan.canvasDelta, 32);
    });

    test('caps canvas movement when the hidden tail becomes fully visible', () {
      final plan = planMobileMousePanAxis(
        delta: 32,
        pointerPosition: 1080,
        visibleStart: 580,
        visibleEnd: 1072,
        displayStart: 0,
        displayEnd: 1080,
      );

      expect(plan.pointerDelta, 8);
      expect(plan.canvasDelta, 8);
    });

    test('moves only the pointer before it crosses the visible midpoint', () {
      final plan = planMobileMousePanAxis(
        delta: 20,
        pointerPosition: 100,
        visibleStart: 0,
        visibleEnd: 600,
        displayStart: 0,
        displayEnd: 1080,
      );

      expect(plan.pointerDelta, 20);
      expect(plan.canvasDelta, 0);
    });

    test('preserves residual drag at the leading display edge', () {
      final plan = planMobileMousePanAxis(
        delta: -24,
        pointerPosition: 0,
        visibleStart: 300,
        visibleEnd: 800,
        displayStart: 0,
        displayEnd: 1080,
      );

      expect(plan.pointerDelta, -24);
      expect(plan.canvasDelta, -24);
    });
  });
}
