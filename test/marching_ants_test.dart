import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Marching Ants: a dashed line whose dashes run toward the arrowhead in the editor and the GIF's final hold.
void main() {
  int rgba(int r, int g, int b) => 0xFF000000 | (b << 16) | (g << 8) | r; // little-endian RGBA bytes

  Future<CanvasState> canvas(LinePattern pattern) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 200, 60), Paint()..color = Colors.white);
    final base = await rec.endRecording().toImage(200, 60);
    return CanvasState(image: base, annotations: [
      Annotation(id: 1, shape: const ArrowShape(Offset(20, 30), Offset(180, 30)),
          arrowStyle: ArrowStyle(end: ArrowHead.none, pattern: pattern, shadow: false)),
    ]);
  }

  /// The pixel row through the line, as "is it painted" flags.
  Future<List<bool>> row(CanvasState state, double? march) async {
    final r = ui.PictureRecorder();
    CanvasPainter(state: state, selectionId: null, scale: 1, march: march == null ? null : ValueNotifier(march))
        .paint(Canvas(r), const Size(200, 60));
    final img = await r.endRecording().toImage(200, 60);
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List();
    return [for (var x = 30; x < 170; x++) px[30 * 200 + x] != rgba(255, 255, 255)];
  }

  test('Marching Ants is offered as a pattern and dashes like Dashed', () {
    expect(LinePattern.values.last, LinePattern.ants);
    expect(LinePattern.ants.label, 'Marching Ants');
    expect(LinePattern.ants.dashes(4), LinePattern.dashed.dashes(4));
    expect(LinePattern.ants.marches, isTrue);
    expect(LinePattern.dashed.marches, isFalse);
    // Saved styles keep it (and older files without it still load)
    const style = ArrowStyle(pattern: LinePattern.ants);
    expect(ArrowStyle.fromJson(style.toJson())!.pattern, LinePattern.ants);
  });

  testWidgets('the dashes move with the march; plain dashes never do', (tester) async {
    await tester.runAsync(() async {
      final ants = await canvas(LinePattern.ants);
      final still = await row(ants, null), start = await row(ants, 0), moved = await row(ants, 0.5);
      expect(still, start, reason: 'no march = the start position, as in a saved PNG');
      expect(start.contains(false) && start.contains(true), isTrue, reason: 'it is dashed');
      expect(moved, isNot(start), reason: 'half a cycle later the dashes have shifted');
      expect(await row(ants, 1 - 1e-9), start, reason: 'a full cycle comes back round');

      final dashed = await canvas(LinePattern.dashed);
      expect(await row(dashed, 0.5), await row(dashed, null), reason: 'Dashed ignores the march');
    });
  });

  testWidgets('the GIF keeps marching through its final hold', (tester) async {
    await tester.runAsync(() async {
      Future<int> frameCount(LinePattern p) async =>
          (await ui.instantiateImageCodec(await BuildUpGif.render(await canvas(p)))).frameCount;
      final dashed = await frameCount(LinePattern.dashed), ants = await frameCount(LinePattern.ants);
      expect(ants, greaterThan(dashed + 10), reason: 'extra frames while the ants run');
    });
  });
}
