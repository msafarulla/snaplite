import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../editor/canvas_painter.dart';
import '../export/build_up_gif.dart';
import '../model/annotation.dart';
import 'manim_doc.dart';

/// A capture as a Manim Studio project: the screenshot (blur and added images baked in) fills the frame as the
/// backdrop, and each arrow, line, pen stroke, box, ellipse, highlight, text, callout and step drawn in the
/// editor becomes a Studio object in the order it was added, ready to animate. Curved arrows keep the path
/// drawn; with Fourier drawing on, drawn paths enter by Fourier Draw.
class ManimFromCapture {
  static ManimDoc convert(CanvasState s, Uint8List backdrop) {
    final w = s.image.width.toDouble(), h = s.image.height.toDouble();
    final k = math.min(ManimDoc.frameW / w, ManimDoc.frameH / h); // scene units per image pixel
    Offset pt(Offset p) => Offset((p.dx - w / 2) * k, (h / 2 - p.dy) * k);
    double stroke(Annotation a) => math.max(1.0, a.lineWidth * k * 100); // Manim stroke widths are 1/100 of a unit
    double font(double px) => px * k * 48 / 0.725; // the Studio's font_size for text `px` image pixels tall

    final doc = ManimDoc(fadeOutAtEnd: false);
    final items = doc.items;
    items.add(MItem(id: doc.newId(), kind: MKind.image, size: Size(w * k, h * k), image: backdrop,
        enter: MEnter.none, runTime: 0.5, wait: 0.6));

    // A drawn path (curved arrow or line, pen stroke) around its centre, as the Studio stores drawings
    MItem path(Annotation a, List<Offset> pts, {required bool tip}) {
      final scene = pts.map(pt).toList();
      final centre = scene.fold(Offset.zero, (p, q) => p + q) / scene.length.toDouble();
      return MItem(id: doc.newId(), kind: MKind.path, pos: centre, points: [for (final q in scene) q - centre],
          arrowTip: tip, color: a.color, stroke: stroke(a), runTime: BuildUpGif.fourier ? 2.8 : 1.2,
          enter: BuildUpGif.fourier ? MEnter.fourier : MEnter.create, showCircles: true);
    }

    var step = 0;
    for (final a in [...s.annotations]..sort((x, y) => x.id.compareTo(y.id))) {
      switch (a.shape) {
        case ArrowShape() || LineShape():
          final style = a.arrowStyle;
          final arrow = a.shape is ArrowShape;
          final head = arrow && style.end != ArrowHead.none, tail = arrow && style.start != ArrowHead.none;
          // A head only at the start: the same arrow drawn the other way
          final flip = tail && !head;
          var pts = CanvasPainter.curveSamples(a.curve!, tangents: a.curveTangents, perSegment: 8);
          if (flip) pts = pts.reversed.toList();
          if (a.curve!.length > 2) {
            items.add(path(a, pts, tip: head || tail));
          } else {
            items.add(MItem(id: doc.newId(), kind: head || tail ? MKind.arrow : MKind.line, pos: pt(pts.first), end: pt(pts.last),
                color: a.color, stroke: stroke(a), doubleHead: head && tail, dashed: style.pattern != LinePattern.solid,
                runTime: 1.2));
          }
        case PenShape(:final points):
          if (points.length < 2) continue;
          items.add(path(a, _thin(points, 80), tip: false));
        case RectShape(:final rect) || EllipseShape(:final rect):
          items.add(MItem(id: doc.newId(), kind: a.shape is RectShape ? MKind.rect : MKind.circle, pos: pt(rect.center),
              size: Size(rect.width * k, rect.height * k), color: a.color, stroke: stroke(a), enter: MEnter.create,
              runTime: 1.2));
        case HighlightShape(:final rect):
          items.add(MItem(id: doc.newId(), kind: MKind.rect, pos: pt(rect.center), size: Size(rect.width * k, rect.height * k),
              color: a.color, fill: 0.4, stroke: 0, enter: MEnter.growFromEdge, runTime: 0.9));
        case TextShape(:final string, :final at):
          final box = _textBox(string, at, a);
          items.add(MItem(id: doc.newId(), kind: MKind.text, text: string, pos: pt(box.center), color: a.color,
              fontSize: font(a.fontSize), font: _family(a), runTime: 0.8));
        case CalloutShape(:final string, :final at):
          final box = CanvasPainter.calloutRect(string, at, a);
          items.add(MItem(id: doc.newId(), kind: MKind.rect, pos: pt(box.center), size: Size(box.width * k, box.height * k),
              color: a.color, fill: 1, stroke: 0, enter: MEnter.grow, runTime: 0.6));
          items.add(MItem(id: doc.newId(), kind: MKind.text, text: string, pos: pt(box.center),
              color: CanvasPainter.calloutTextColor(a), fontSize: font(a.fontSize), font: _family(a), withPrevious: true,
              runTime: 0.6));
        case StepShape(:final center):
          step++;
          final d = a.stepDiameter * k;
          items.add(MItem(id: doc.newId(), kind: MKind.circle, pos: pt(center), size: Size(d, d), color: a.color, fill: 1,
              stroke: 0, enter: MEnter.grow, runTime: 0.6));
          items.add(MItem(id: doc.newId(), kind: MKind.text, text: '$step', pos: pt(center),
              color: CanvasPainter.contrast(a.color), fontSize: font(a.stepDiameter * 0.55), withPrevious: true, runTime: 0.6));
        case SpotlightShape() || BlurShape() || ImageShape():
          break; // blur and images are in the backdrop; the Studio has no spotlight
      }
    }
    return doc;
  }

  /// The text's font (the editor's system font has no name Manim knows, so the Studio's default sans).
  /// The Studio has no bold, italic or underline, so those don't carry over.
  static String _family(Annotation a) => a.textFormat.family.isEmpty ? 'Helvetica Neue' : a.textFormat.family;

  /// A text annotation's box (its `at` is the top-left corner).
  static Rect _textBox(String string, Offset at, Annotation a) {
    final tp = TextPainter(
      text: TextSpan(text: string, style: TextStyle(fontSize: a.fontSize, fontWeight: a.textFormat.bold ? FontWeight.bold : null)),
      textDirection: TextDirection.ltr,
    )..layout();
    return at & tp.size;
  }

  /// At most `max` points, evenly picked, keeping the ends.
  static List<Offset> _thin(List<Offset> pts, int max) {
    if (pts.length <= max) return pts;
    return [for (var i = 0; i < max; i++) pts[(i * (pts.length - 1) / (max - 1)).round()]];
  }
}
