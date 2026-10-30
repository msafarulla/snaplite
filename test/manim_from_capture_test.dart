import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/export/manim_scene.dart';
import 'package:snaplite_flutter/manim/from_capture.dart';
import 'package:snaplite_flutter/manim/manim_doc.dart';
import 'package:snaplite_flutter/model/annotation.dart';

Future<ui.Image> _image(int w, int h) async {
  final r = ui.PictureRecorder();
  final c = Canvas(r)..drawColor(const Color(0xFFDDE6F0), BlendMode.src);
  c.drawRect(const Rect.fromLTWH(60, 60, 300, 160), Paint()..color = Colors.white);
  return r.endRecording().toImage(w, h);
}

CanvasState _sample(ui.Image img) => CanvasState(image: img, annotations: [
      const Annotation(id: 1, shape: RectShape(Rect.fromLTWH(60, 60, 300, 160)), color: Color(0xFF007AFF)),
      const Annotation(id: 2, shape: ArrowShape(Offset(500, 380), Offset(370, 220), points: [Offset(470, 260)])),
      const Annotation(id: 3, shape: ArrowShape(Offset(560, 120), Offset(420, 160))),
      const Annotation(id: 4, shape: TextShape('Click Save', Offset(420, 400))),
      const Annotation(id: 5, shape: StepShape(Offset(90, 420))),
      const Annotation(id: 6, shape: HighlightShape(Rect.fromLTWH(80, 100, 200, 30)), color: Color(0xFFFFCC00)),
      const Annotation(id: 7, shape: BlurShape(Rect.fromLTWH(500, 40, 100, 60), null)),
      const Annotation(id: 8, shape: PenShape([Offset(100, 380), Offset(140, 340), Offset(180, 390), Offset(230, 350)]), color: Color(0xFF34C759)),
      const Annotation(id: 10, shape: ArrowShape(Offset(300, 300), Offset(400, 300)), arrowStyle: ArrowStyle(start: ArrowHead.triangle, end: ArrowHead.none)),
      const Annotation(id: 9, shape: CalloutShape('Two\nlines', Offset(120, 280), tail: Offset(200, 230)), color: Color(0xFFFFCC00)),
    ]);

void main() {
  test('everything drawn on the capture becomes a Studio object, in order, over the screenshot', () async {
    final s = _sample(await _image(640, 480));
    final doc = ManimFromCapture.convert(s, await ManimScene.backdrop(s));
    final kinds = [for (final i in doc.items) i.kind];
    expect(kinds, [
      MKind.image, // the screenshot, already there
      MKind.rect,
      MKind.path, // the curved arrow keeps its drawn path
      MKind.arrow, // a straight one is a Manim arrow
      MKind.text,
      MKind.circle, MKind.text, // the step: disc and number together
      MKind.rect, // highlight
      MKind.path, // pen stroke (blur is baked into the screenshot)
      MKind.rect, MKind.text, // callout
      MKind.arrow, // head only at the start
    ]);
    final back = doc.items.last;
    expect(back.pos.dx, greaterThan(back.end.dx), reason: 'drawn the other way, so its head is where the start head was');
    expect(back.doubleHead, isFalse);
    expect(doc.items.first.enter, MEnter.none);
    expect(doc.items.first.size.height, closeTo(ManimDoc.frameH, 0.01), reason: 'a 4:3 capture fills the frame height');
    final curved = doc.items[2];
    expect(curved.arrowTip, isTrue);
    expect(curved.points.length, greaterThan(4));
    expect(curved.enter, MEnter.create);
    final box = doc.items[1];
    expect(box.pos.dx, closeTo((210 - 320) * 8 / 480, 0.01), reason: 'placed where it was drawn');
    expect(box.pos.dy, closeTo((240 - 140) * 8 / 480, 0.01));
    expect(doc.items[6].withPrevious, isTrue, reason: "the step's number arrives with its disc");
    expect(doc.code(), contains('class ${ManimDoc.className}('));
  });

  // Writes the project's scene for a manual render with the real Manim (SNAPNOW_MANIM_DIR; not in CI)
  test('writes a renderable scene', () async {
    final dir = Platform.environment['SNAPNOW_MANIM_DIR'];
    if (dir == null) return;
    final s = _sample(await _image(640, 480));
    final doc = ManimFromCapture.convert(s, await ManimScene.backdrop(s));
    File('$dir/scene.py').writeAsStringSync(doc.code());
    for (final i in doc.items) {
      if (i.image != null) File('$dir/image_${i.id}.png').writeAsBytesSync(i.image!);
    }
  });
}
