import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';

void main() {
  test('a callout bubble smaller than its pointer margins still draws (no clamp error)', () {
    const box = Rect.fromLTWH(100, 100, 30, 24); // tiny bubble for a 40 pt font
    for (final tail in const [Offset(115, 300), Offset(115, -100), Offset(400, 112), Offset(-200, 112)]) {
      final path = CanvasPainter.calloutPath(box, tail, 40);
      expect(path.getBounds().inflate(1).contains(tail), isTrue, reason: 'the pointer reaches $tail');
    }
  });
}
