import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../editor/canvas_painter.dart';
import '../manim/manim_doc.dart';
import '../model/annotation.dart';
import 'build_up_gif.dart';
import 'epicycles.dart';

/// A Manim (Community) scene made from a capture: the screenshot as the backdrop, then each annotation as a
/// Manim object, animated in the order it was added, like the build-up GIF: arrows and curves draw on along
/// their path, Fourier circles trace them when Fourier drawing is on, dashes stay dashes (marching ones keep
/// running), text writes itself, steps grow, highlights wipe in, a spotlight dims the rest. Same timings as
/// the GIF. The user edits the code in SnapNow's Manim page and renders it there.
class ManimScene {
  static const className = 'SnapScene';
  static const backdropFile = 'capture.png';

  /// The backdrop: the capture with Blur patches and added images baked in, so blurred content never
  /// reaches the scene (the annotations that get animated are left out).
  static Future<Uint8List> backdrop(CanvasState s) async {
    final kept = [for (final a in s.annotations) if (a.shape is BlurShape || a.shape is ImageShape) a];
    final recorder = ui.PictureRecorder();
    final w = s.image.width.toDouble(), h = s.image.height.toDouble();
    CanvasPainter(state: s.copyWith(annotations: kept), selectionId: null, scale: 1).paint(Canvas(recorder), Size(w, h));
    final img = await recorder.endRecording().toImage(s.image.width, s.image.height);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  /// The frame's aspect ratio (width / height), for the render's -r option.
  static double aspect(CanvasState s) => s.image.width / s.image.height;

  /// The Python source of the scene.
  static String code(CanvasState s) {
    final w = s.image.width.toDouble(), h = s.image.height.toDouble();
    final k = 8 / h; // scene units per image pixel (the frame is 8 units tall)
    String n(double v) => v.toStringAsFixed(3);
    String pt(Offset p) => '[${n((p.dx - w / 2) * k)}, ${n((h / 2 - p.dy) * k)}, 0]';
    String col(Color c) => '"#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}"';
    double sw(Annotation a) => math.max(1.0, a.lineWidth * k * 100); // Manim stroke widths are 1/100 of a unit

    final order = [...s.annotations]..sort((x, y) => x.id.compareTo(y.id));
    final fourier = BuildUpGif.fourier && order.any(Epicycles.fits);
    final dashed = order.any((a) => a.styleKind != null && a.arrowStyle.pattern != LinePattern.solid &&
        (a.shape is ArrowShape || a.shape is LineShape || a.shape is PenShape));
    String secs(Duration d) => n(d.inMilliseconds / 1000);

    final out = StringBuffer()
      ..writeln('# Made by SnapNow from a capture. Edit freely, then Render.')
      ..writeln('# Coordinates: the frame is 8 units tall, centred on the capture.')
      ..writeln('from manim import *')
      ..writeln()
      ..writeln('config.frame_height = 8')
      ..writeln('config.frame_width = ${n(8 * aspect(s))}')
      ..writeln();
    if (dashed) out.write(_dashHelper);
    if (fourier) out.write(ManimDoc.fourierHelper);
    out
      ..writeln()
      ..writeln('class $className(Scene):')
      ..writeln('    def construct(self):')
      ..writeln('        capture = ImageMobject("$backdropFile").scale_to_fit_height(config.frame_height)')
      ..writeln('        self.add(capture)')
      ..writeln('        self.wait(${secs(BuildUpGif.openingHold)})');

    var step = 0;
    final holes = <String>[]; // spotlights so far: each opens on its own turn, in one shared dimmed layer
    for (final a in order) {
      final c = col(a.color);
      final lines = <String>[], after = <String>[];
      String? play;
      String? traced; // what Fourier circles trace (then it turns into the finished mob)
      var closed = false;
      switch (a.shape) {
        case ArrowShape() || LineShape() || PenShape():
          final pts = a.curve != null
              ? CanvasPainter.curveSamples(a.curve!, tangents: a.curveTangents, perSegment: 8)
              : switch (a.shape) { PenShape(:final points) => _thin(points, 60), _ => const <Offset>[] };
          if (pts.length < 2) continue;
          final smooth = pts.length > 2;
          lines.add('path = TipableVMobject(color=$c, stroke_width=${n(sw(a))})');
          lines.add(smooth
              ? 'path.set_points_smoothly([${pts.map(pt).join(', ')}])'
              : 'path.set_points_as_corners([${pts.map(pt).join(', ')}])');
          final isArrow = a.shape is ArrowShape;
          final style = a.arrowStyle;
          if (isArrow || a.shape is LineShape) {
            final tip = n(math.max(a.lineWidth * 3.5, 14 * a.scale) * k);
            if (style.end != ArrowHead.none) lines.add('path.add_tip(tip_length=$tip, tip_width=$tip)');
            if (style.start != ArrowHead.none) lines.add('path.add_tip(tip_length=$tip, tip_width=$tip, at_start=True)');
          }
          final dashes = style.pattern.still.dashes(a.lineWidth);
          if (dashes != null) {
            // The editor's dash/gap sequence (dash-dot has four); a near-zero dash is a dot (0)
            final seq = [for (final d in dashes) n(d < 1 ? 0 : d * k)];
            lines.add('mob = snapnow_dashes(path, [${seq.join(', ')}], ${n(a.lineWidth * k)}, $c)');
            if (style.pattern.marches) after.add('snapnow_march(mob)');
          } else {
            lines.add('mob = path');
          }
          traced = 'path';
          play = 'Create(mob)';
        case RectShape(:final rect) || EllipseShape(:final rect):
          final kind = a.shape is RectShape ? 'Rectangle' : 'Ellipse';
          lines.add('mob = $kind(width=${n(rect.width * k)}, height=${n(rect.height * k)}, color=$c, '
              'stroke_width=${n(sw(a))}).move_to(${pt(rect.center)})');
          traced = 'mob';
          closed = true;
          play = 'Create(mob)';
        case HighlightShape(:final rect):
          lines.add('mob = Rectangle(width=${n(rect.width * k)}, height=${n(rect.height * k)}, stroke_width=0, '
              'fill_color=$c, fill_opacity=0.4).move_to(${pt(rect.center)})');
          play = 'GrowFromEdge(mob, LEFT)';
        case TextShape(:final string, :final at):
          lines.add(_text(string, at, a, c, k, pt, n));
          play = 'Write(mob)';
        case CalloutShape(:final string, :final at, :final tail):
          final box = CanvasPainter.calloutRect(string, at, a);
          lines.add(_text(string, at, a, col(CanvasPainter.calloutTextColor(a)), k, pt, n).replaceFirst('mob = ', 'words = '));
          lines.add('bubble = RoundedRectangle(corner_radius=${n(a.fontSize * 0.35 * k)}, width=${n(box.width * k)}, '
              'height=${n(box.height * k)}, stroke_width=0, fill_color=$c, fill_opacity=1).move_to(${pt(box.center)})');
          if (tail != null) {
            final d = tail - box.center, len = d.distance;
            final perp = len == 0 ? Offset.zero : Offset(-d.dy, d.dx) / len * (a.fontSize * 0.45);
            lines.add('pointer = Polygon(${pt(box.center + perp)}, ${pt(tail)}, ${pt(box.center - perp)}, stroke_width=0, '
                'fill_color=$c, fill_opacity=1)');
            lines.add('mob = Group(pointer, bubble, words)');
          } else {
            lines.add('mob = Group(bubble, words)');
          }
          play = 'FadeIn(mob, scale=0.8)';
        case StepShape(:final center):
          final d = a.stepDiameter;
          lines.add('disc = Circle(radius=${n(d / 2 * k)}, stroke_width=0, fill_color=$c, fill_opacity=1).move_to(${pt(center)})');
          lines.add('num = Text("${step + 1}", font="Helvetica Neue", color=${col(CanvasPainter.contrast(a.color))}, weight=BOLD)'
              '.scale_to_fit_height(${n(d * 0.5 * k)}).move_to(${pt(center)})');
          lines.add('mob = Group(disc, num)');
          play = 'GrowFromCenter(mob)';
        case SpotlightShape(:final rect):
          // One dimmed layer for all spotlights (two would dim twice): the first fades it in, later ones open
          // their hole in it. It sits under the markup, as in the editor, so only the capture gets dimmed.
          holes.add('RoundedRectangle(corner_radius=${n(8 * k)}, width=${n(rect.width * k)}, height=${n(rect.height * k)})'
              '.move_to(${pt(rect.center)})');
          final dim = 'Difference(Rectangle(width=config.frame_width, height=config.frame_height), '
              'Union(${holes.join(', ')}, Dot(radius=0)), fill_color=BLACK, fill_opacity=0.55, stroke_width=0)';
          if (holes.length == 1) {
            lines.addAll(['dim = $dim', 'self.add(dim)', 'self.bring_to_back(dim)', 'self.bring_to_back(capture)']);
            play = 'FadeIn(dim)';
          } else {
            play = 'Transform(dim, $dim)';
          }
        case BlurShape() || ImageShape():
          break; // baked into the backdrop
      }
      if (a.shape is StepShape) step++;
      if (play == null) continue;
      out
        ..writeln()
        ..writeln('        # ${_label(a)}');
      for (final l in lines) {
        out.writeln('        $l');
      }
      if (fourier && traced != null) {
        // Circles on circles trace it (faint, as in the editor), then it becomes the finished stroke
        out
          ..writeln('        trace = snapnow_fourier(self, $traced, 80, ${secs(BuildUpGif.fourierDraw)}, $c, ${n(sw(a))}, '
              '${closed ? 'True' : 'False'}, True, circle_color=WHITE, circle_opacity=0.15, arm_color=$c)')
          ..writeln('        self.play(FadeTransform(trace, mob), run_time=0.4)');
      } else {
        out.writeln('        self.play($play, run_time=${secs(BuildUpGif.appearing(a))})');
      }
      for (final l in after) {
        out.writeln('        $l');
      }
      out.writeln('        self.wait(${secs(BuildUpGif.pauseAfterEach)})');
    }
    out..writeln()..writeln('        self.wait(${secs(BuildUpGif.finalHold - BuildUpGif.pauseAfterEach)})');
    return out.toString();
  }

  /// Dashes (or dots) along a path, with its arrowheads kept whole; snapnow_march keeps them running toward
  /// the end, one dash cycle every 0.8 s like the editor's Marching Ants.
  static const _dashHelper = '''
def snapnow_dashes(path, pattern, width, color):
    """pattern: dash, gap, dash, gap… in scene units; a 0 dash is a dot."""
    base = path.copy()
    tips = base.pop_tips() if isinstance(base, TipableVMobject) else VGroup()
    length = max(base.get_arc_length(), 1e-6)
    steps = [p / length for p in pattern]
    group = VGroup()
    group.snapnow = dict(base=base, tips=tips, steps=steps, cycle=sum(steps), width=width, color=color, shift=0.0)
    _snapnow_build(group)
    return group


def _snapnow_build(group):
    o = group.snapnow
    parts = []
    s = o["shift"] % o["cycle"] - o["cycle"]
    while s < 1:
        for i in range(0, len(o["steps"]), 2):
            dash, gap = o["steps"][i], o["steps"][i + 1]
            a, b = max(0.0, s), min(1.0, s + dash)
            if dash == 0 and 0 <= s <= 1:
                parts.append(Dot(o["base"].point_from_proportion(s), radius=o["width"] / 2, color=o["color"]))
            elif dash > 0 and b > a:
                parts.append(o["base"].get_subcurve(a, b))
            s += dash + gap
    group.submobjects = [*parts, *o["tips"]]


def snapnow_march(group):
    def run(m, dt):
        m.snapnow["shift"] += dt * m.snapnow["cycle"] / 0.8
        _snapnow_build(m)
    group.add_updater(run)

''';

  /// Text with its top-left at `at`, about the editor's size.
  static String _text(String string, Offset at, Annotation a, String color, double k, String Function(Offset) pt,
      String Function(double) n) {
    final lines = '\n'.allMatches(string).length + 1;
    final weight = a.textFormat.bold ? ', weight=BOLD' : '';
    final slant = a.textFormat.italic ? ', slant=ITALIC' : '';
    // The editor's font (its system font isn't available to Manim by name, so a close sans instead)
    final font = jsonEncode(a.textFormat.family.isEmpty ? 'Helvetica Neue' : a.textFormat.family);
    return 'mob = Text(${jsonEncode(string)}, font=$font, color=$color$weight$slant, line_spacing=0.8)'
        '.scale_to_fit_height(${n(a.fontSize * 0.95 * lines * k)}).move_to(${pt(at)}, aligned_edge=UL)';
  }

  static String _label(Annotation a) => switch (a.shape) {
        ArrowShape() => 'Arrow',
        LineShape() => 'Line',
        PenShape() => 'Pen stroke',
        RectShape() => 'Rectangle',
        EllipseShape() => 'Ellipse',
        HighlightShape() => 'Highlight',
        TextShape(:final string) => 'Text: ${string.split('\n').first}',
        CalloutShape(:final string) => 'Callout: ${string.split('\n').first}',
        StepShape() => 'Step',
        _ => 'Annotation',
      };

  /// At most `max` points, evenly picked, keeping the ends.
  static List<Offset> _thin(List<Offset> pts, int max) {
    if (pts.length <= max) return pts;
    return [for (var i = 0; i < max; i++) pts[(i * (pts.length - 1) / (max - 1)).round()]];
  }
}
