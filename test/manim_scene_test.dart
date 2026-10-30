import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/export/manim_scene.dart';
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
      const Annotation(id: 3, shape: TextShape('Click "Save"', Offset(420, 400))),
      const Annotation(id: 4, shape: CalloutShape('Two\nlines', Offset(120, 300), tail: Offset(200, 230)), color: Color(0xFFFFCC00)),
      const Annotation(id: 5, shape: StepShape(Offset(90, 420))),
      const Annotation(id: 6, shape: HighlightShape(Rect.fromLTWH(80, 100, 200, 30)), color: Color(0xFFFFCC00)),
      const Annotation(id: 7, shape: BlurShape(Rect.fromLTWH(500, 40, 100, 60), null)),
      const Annotation(id: 8, shape: LineShape(Offset(420, 460), Offset(620, 460)), arrowStyle: ArrowStyle(end: ArrowHead.none, pattern: LinePattern.dashed)),
      const Annotation(id: 9, shape: ArrowShape(Offset(560, 120), Offset(420, 160)), arrowStyle: ArrowStyle(pattern: LinePattern.ants)),
      const Annotation(id: 10, shape: SpotlightShape(Rect.fromLTWH(60, 60, 300, 160))),
      const Annotation(id: 12, shape: SpotlightShape(Rect.fromLTWH(400, 360, 220, 70))),
      const Annotation(id: 13, shape: LineShape(Offset(60, 250), Offset(360, 250)), arrowStyle: ArrowStyle(end: ArrowHead.none, pattern: LinePattern.dashDot)),
      const Annotation(id: 11, shape: PenShape([Offset(100, 380), Offset(140, 340), Offset(180, 390), Offset(230, 350)]), color: Color(0xFF34C759)),
    ]);

void main() {
  test('the scene has every annotation, in order, as Manim objects', () async {
    final code = ManimScene.code(_sample(await _image(640, 480)));
    expect(code, contains('class ${ManimScene.className}(Scene):'));
    expect(code, contains('ImageMobject("${ManimScene.backdropFile}")'));
    final order = ['Rectangle(', 'add_tip(', 'Text("Click \\"Save\\"", font=', 'RoundedRectangle(', 'Circle(', 'GrowFromEdge(',
        'snapnow_dashes(path', 'snapnow_march(mob)', 'Difference(', 'set_points_smoothly('];
    var at = 0;
    for (final o in order) {
      final i = code.indexOf(o, at);
      expect(i, greaterThan(-1), reason: '$o in creation order');
      at = i;
    }
    expect(code, isNot(contains('Blur')), reason: 'blur is baked into the backdrop, not animated');
    expect(code, contains('FadeIn(dim)'), reason: 'the first spotlight dims the capture');
    expect(code, contains('Transform(dim, '), reason: 'a later spotlight opens its own hole on its turn');
    expect(code, matches(RegExp(r'snapnow_dashes\(path, \[[\d.]+, [\d.]+, 0\.000, [\d.]+\]')), reason: 'dash-dot keeps its dot');
  });

  test('Fourier drawing on: circles trace lines, pen strokes and outlines first', () async {
    BuildUpGif.fourier = true;
    addTearDown(() => BuildUpGif.fourier = false);
    final code = ManimScene.code(_sample(await _image(640, 480)));
    expect(code, contains('def snapnow_fourier('));
    expect('snapnow_fourier(self, '.allMatches(code).length, 6, reason: 'rectangle, 4 arrows/lines, pen stroke');
    expect(code, contains('snapnow_fourier(self, mob, 80, 2.800, "#007AFF"'), reason: 'the box, closed');
    expect(code, contains('circle_opacity=0.15'));
    expect(ManimScene.code(_sample(await _image(640, 480))), contains('FadeTransform(trace, mob)'));
  });

  // Renders with the real Manim when SNAPNOW_MANIM_DIR is set (a manual check; Manim isn't in CI)
  test('writes a renderable scene', () async {
    final dir = Platform.environment['SNAPNOW_MANIM_DIR'];
    if (dir == null) return;
    final s = _sample(await _image(640, 480));
    BuildUpGif.fourier = Platform.environment['SNAPNOW_MANIM_FOURIER'] == '1';
    addTearDown(() => BuildUpGif.fourier = false);
    File('$dir/scene.py').writeAsStringSync(ManimScene.code(s));
    File('$dir/${ManimScene.backdropFile}').writeAsBytesSync(await ManimScene.backdrop(s));
  });
}
