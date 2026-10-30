import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/export/epicycles.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Fourier circles in the build-up GIF: the chain's tip follows the stroke as it draws on.
void main() {
  // A wavy pen stroke
  final wave = [for (var i = 0; i <= 60; i++) Offset(40 + i * 5.0, 120 + 50 * math.sin(i / 6))];
  const pen = 1, box = 2, arrow = 3;
  final annotations = [
    Annotation(id: pen, shape: PenShape(wave)),
    const Annotation(id: box, shape: RectShape(Rect.fromLTWH(60, 200, 220, 70))),
    const Annotation(id: arrow, shape: ArrowShape(Offset(380, 60), Offset(380, 260))),
  ];

  test('the tip sits where the stroke has drawn to, out and (for outlines) all the way round', () {
    for (final a in annotations) {
      final e = Epicycles.of(a)!;
      final metric = CanvasPainter.outlinePath(a).computeMetrics().first;
      for (final f in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final want = metric.getTangentForOffset(metric.length * f)!.position;
        expect((e.chain(f).last - want).distance, lessThan(10), reason: '${a.shape.runtimeType} at $f'); // a box's corners round off a little
      }
    }
    expect(Epicycles.of(const Annotation(id: 9, shape: TextShape('hi', Offset.zero))), isNull, reason: 'text fades in as before');
  });

  testWidgets('a frame mid-stroke shows the circles; off, it does not', (t) async {
    await t.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 460, 320), Paint()..color = const Color(0xFF2B3440));
      final base = await rec.endRecording().toImage(460, 320);
      final state = CanvasState(image: base, annotations: annotations);
      Future<ui.Image> shot(bool on) async {
        final r = ui.PictureRecorder();
        CanvasPainter(state: state, selectionId: null, scale: 1, progress: {pen: 1, box: 0.6, arrow: 0.5}, epicycles: on)
            .paint(Canvas(r), const Size(460, 320));
        return r.endRecording().toImage(460, 320);
      }

      final on = await shot(true), off = await shot(false);
      final a = (await on.toByteData())!.buffer.asUint32List(), b = (await off.toByteData())!.buffer.asUint32List();
      var differ = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) differ++;
      }
      expect(differ, greaterThan(500), reason: 'circles and arms drawn');
      final out = Platform.environment['EPICYCLE_PNG'];
      if (out != null) File(out).writeAsBytesSync((await on.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  });

  test('traced strokes appear slower so the circles can be seen', () {
    BuildUpGif.fourier = true;
    addTearDown(() => BuildUpGif.fourier = false);
    expect(BuildUpGif.appearing(annotations.first), const Duration(milliseconds: 1800));
  });
}
