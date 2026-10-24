import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Renders every arrowhead (plain and tapered) to a PNG for eyeballing: SNAPLITE_RENDER_DIR=/path flutter test …
void main() {
  final out = Platform.environment['SNAPLITE_RENDER_DIR'];
  testWidgets('render arrowheads', (tester) async {
    if (out == null) return;
    const cell = Size(300, 110);
    final heads = ArrowHead.values.where((h) => h != ArrowHead.none).toList();
    final size = Size(cell.width * 3, cell.height * heads.length);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1E1F2A));
    for (final (row, head) in heads.indexed) {
      for (final (col, tapered) in [false, true, true].indexed) {
        final o = Offset(col * cell.width, row * cell.height);
        // Third column: bent through two points on the curve
        final shape = col < 2
            ? ArrowShape(o + const Offset(270, 25), o + const Offset(40, 85))
            : ArrowShape(o + const Offset(270, 25), o + const Offset(40, 85), points: [o + const Offset(200, 80), o + const Offset(110, 30)]);
        final a = Annotation(id: 0, shape: shape,
            color: const Color(0xFFE8332A), size: StrokeSize.medium, scale: 2,
            arrowStyle: ArrowStyle(end: head, tapered: tapered));
        CanvasPainter.drawAnnotation(canvas, a);
      }
    }
    await tester.runAsync(() async {
      final img = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$out/arrows.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
