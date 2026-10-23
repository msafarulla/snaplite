import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../model/annotation.dart';

/// Renders a [CanvasState] (base image + annotations) and the selection chrome.
/// Everything is drawn in image coordinates; the widget wraps it in a FittedBox-style scale.
/// Arrow/line/shape drawing is a port of the Swift app's Renderer (heads, tapering, patterns,
/// outline, shadow), so annotations look the same in both.
class CanvasPainter extends CustomPainter {
  final CanvasState state;
  final int? selectionId;
  final double scale; // view points per image point, for crisp 1px handles

  CanvasPainter({required this.state, required this.selectionId, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save(); // the gesture preview paints after this, so leave the canvas unscaled
    _paintScaled(canvas);
    canvas.restore();
  }

  void _paintScaled(Canvas canvas) {
    canvas.scale(scale); // draw everything in image coordinates
    final img = state.image;
    final imageRect = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    canvas.drawRect(imageRect, Paint()..color = state.background); // canvas colour behind the image
    canvas.drawImage(img, Offset.zero, Paint());

    // Blur patches first, then spotlight dimming, then the rest in order.
    final spotlights = <Rect>[];
    for (final a in state.annotations) {
      switch (a.shape) {
        case BlurShape():
          drawAnnotation(canvas, a, base: img);
        case SpotlightShape(:final rect):
          spotlights.add(rect);
        default:
          break;
      }
    }
    if (spotlights.isNotEmpty) _drawSpotlight(canvas, spotlights, imageRect);

    var step = 0;
    for (final a in state.annotations) {
      switch (a.shape) {
        case BlurShape():
        case SpotlightShape():
          continue;
        case StepShape():
          step += 1;
          drawAnnotation(canvas, a, number: step);
        default:
          drawAnnotation(canvas, a);
      }
    }

  }

  /// The selection's handles (drawn separately so the image clip doesn't cut off handles on its edge).
  void paintSelection(Canvas canvas) {
    final sel = state.annotations.where((a) => a.id == selectionId).firstOrNull;
    if (sel == null) return;
    canvas.save();
    canvas.scale(scale);
    _drawSelection(canvas, sel);
    canvas.restore();
  }

  /// Draws one annotation (also used for Quick Style tiles and previews).
  static void drawAnnotation(Canvas canvas, Annotation a, {int number = 0, ui.Image? base}) {
    final w = a.lineWidth;
    switch (a.shape) {
      case ArrowShape(:final from, :final to, :final bend) || LineShape(:final from, :final to, :final bend):
        drawArrow(canvas, from, control(from, to, bend), to, a.arrowStyle, a.color, w);
      case RectShape(:final rect):
        strokeStyled(canvas, Path()..addRRect(RRect.fromRectXY(rect, 2, 2)), a.arrowStyle, a.color, w);
      case EllipseShape(:final rect):
        strokeStyled(canvas, Path()..addOval(rect), a.arrowStyle, a.color, w);
      case HighlightShape(:final rect):
        canvas.drawRect(rect, Paint()..color = a.color.withValues(alpha: 0.45)..blendMode = BlendMode.multiply);
      case PenShape(:final points):
        strokeStyled(canvas, _smooth(points), a.arrowStyle, a.color, w);
      case TextShape(:final string, :final at):
        _text(string, a.color, a.fontSize, halo: true).paint(canvas, at);
      case CalloutShape(:final string, :final at, :final tail):
        _callout(canvas, string, at, tail, a);
      case StepShape(:final center):
        _step(canvas, center, number, a);
      case BlurShape(:final rect):
        if (base == null) break;
        // Live blur of the base image within the rect (no precomputed patch needed).
        canvas.save();
        canvas.clipRRect(RRect.fromRectXY(rect, 2, 2));
        canvas.drawImageRect(base, rect, rect,
            Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: TileMode.clamp));
        canvas.restore();
      case ImageShape(:final rect, :final image):
        canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect,
            Paint()..filterQuality = FilterQuality.high);
      case SpotlightShape():
        break;
    }
  }

  // ---- Arrows and lines ----

  /// Quadratic control point that makes the curve pass through mid + bend.
  static Offset control(Offset a, Offset b, Offset bend) {
    final mid = Offset((a.dx + b.dx) / 2 + bend.dx, (a.dy + b.dy) / 2 + bend.dy);
    return Offset(2 * mid.dx - (a.dx + b.dx) / 2, 2 * mid.dy - (a.dy + b.dy) / 2);
  }

  static Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return Offset(u * u * a.dx + 2 * u * t * c.dx + t * t * b.dx, u * u * a.dy + 2 * u * t * c.dy + t * t * b.dy);
  }

  static Offset _unit(Offset from, Offset to) {
    final d = to - from;
    final len = math.max(d.distance, 0.0001);
    return d / len;
  }

  /// A head at `tip`, pointing away from `from`. `trim` is where the body stops so its cap hides under the head.
  static _Head _head(ArrowHead kind, Offset tip, Offset from, double w, double k) {
    final u = _unit(from, tip);
    final n = Offset(-u.dy, u.dx);
    Offset at(double along, double across) => tip - u * along + n * across;
    Path polygon(List<Offset> pts) => Path()..addPolygon(pts, true);
    Path stroked(List<Offset> pts) => Path()..addPolygon(pts, false);
    final length = math.max(14.0, w * 5) * k, half = length * 0.55;
    final thin = math.max(1.5, w * 0.6);
    switch (kind) {
      case ArrowHead.none:
        return _Head(null, trim: tip);
      case ArrowHead.triangle:
        return _Head(polygon([tip, at(length, half), at(length, -half)]), trim: at(length * 0.8, 0));
      case ArrowHead.swept:
        return _Head(polygon([tip, at(length * 1.1, half), at(length * 0.7, 0), at(length * 1.1, -half)]),
            trim: at(length * 0.6, 0));
      case ArrowHead.triangleOutline:
        return _Head(polygon([tip, at(length, half), at(length, -half)]), filled: false, lineWidth: thin,
            trim: at(length, 0));
      case ArrowHead.open:
        return _Head(stroked([at(length * 0.75, half), tip, at(length * 0.75, -half)]), filled: false, lineWidth: w,
            trim: tip);
      case ArrowHead.dot:
        final r = math.max(4.0, w * 1.4) * k;
        return _Head(Path()..addOval(Rect.fromCircle(center: tip, radius: r)), trim: tip);
      case ArrowHead.circle:
        final r = math.max(5.0, w * 1.8) * k;
        return _Head(Path()..addOval(Rect.fromCircle(center: tip, radius: r)), filled: false, lineWidth: thin,
            trim: at(r, 0));
      case ArrowHead.square:
        final s = math.max(4.0, w * 1.4) * k;
        return _Head(polygon([at(-s, s), at(-s, -s), at(s, -s), at(s, s)]), trim: tip);
      case ArrowHead.diamond:
        final d = math.max(8.0, w * 2.8) * k;
        return _Head(polygon([at(-d, 0), at(0, d * 0.7), at(d, 0), at(0, -d * 0.7)]), trim: tip);
      case ArrowHead.bar:
        final s = math.max(7.0, w * 2.4) * k;
        return _Head(stroked([at(0, s), at(0, -s)]), filled: false, lineWidth: w, trim: tip);
    }
  }

  /// A filled outline whose width grows from a thin tail to the head end.
  static Path _taperedBody(Offset a, Offset c, Offset b, double width) {
    const count = 40;
    final points = [for (var i = 0; i <= count; i++) _quad(a, c, b, i / count)];
    final left = <Offset>[], right = <Offset>[];
    for (var i = 0; i <= count; i++) {
      final t = i / count;
      final u = _unit(points[math.max(i - 1, 0)], points[math.min(i + 1, count)]);
      final half = width * (0.15 + 0.85 * t) * 0.9;
      left.add(Offset(points[i].dx - u.dy * half, points[i].dy + u.dx * half));
      right.add(Offset(points[i].dx + u.dy * half, points[i].dy - u.dx * half));
    }
    return Path()..addPolygon([...left, ...right.reversed], true);
  }

  /// Black on light colors, white on dark ones (outline and callout/step text).
  static Color contrast(Color c) {
    final hsv = HSVColor.fromColor(c);
    return hsv.value > 0.75 && hsv.saturation < 0.6 ? Colors.black : Colors.white;
  }

  /// `path` cut into dashes (near-zero dashes become dots under round caps).
  static Path dashed(Path path, List<double>? dashes, {double phase = 0}) {
    if (dashes == null) return path;
    final out = Path();
    for (final metric in path.computeMetrics()) {
      var d = -phase, i = 0;
      while (d < metric.length) {
        final len = dashes[i % dashes.length];
        final from = math.max(d, 0.0), to = math.min(d + math.max(len, 0.01), metric.length);
        if (i.isEven && to > from) out.addPath(metric.extractPath(from, to), Offset.zero);
        d += len;
        i++;
      }
    }
    return out;
  }

  /// Runs `render` for the shadow (once, for the whole annotation), the contrast outline (widened by
  /// `outlineWidth`) and the real color, like the Swift app's transparency-layer approach.
  static void _styled(Canvas canvas, ArrowStyle style, Color color, double outlineWidth,
      void Function(Color paint, double extra) render) {
    if (style.shadow) {
      canvas.saveLayer(null, Paint()
        ..colorFilter = ColorFilter.mode(Colors.black.withValues(alpha: 0.4), BlendMode.srcIn)
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 1.6, sigmaY: 1.6));
      canvas.translate(1.5, 1.5);
      if (style.outline) render(contrast(color), outlineWidth);
      render(color, 0);
      canvas.restore();
    }
    if (style.outline) render(contrast(color), outlineWidth);
    render(color, 0);
  }

  static Paint _stroke(Color c, double width) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static Paint _fill(Color c) => Paint()..color = c..style = PaintingStyle.fill;

  /// Boxes, ellipses and pen strokes: pattern, outline and shadow.
  static void strokeStyled(Canvas canvas, Path path, ArrowStyle style, Color color, double w) {
    final p = dashed(path, style.pattern.dashes(w));
    _styled(canvas, style, color, math.max(1.5, w * 0.35), (paint, extra) {
      canvas.drawPath(p, _stroke(paint, w + extra * 2));
    });
  }

  /// An arrow or line along the quadratic a → b with control point c.
  static void drawArrow(Canvas canvas, Offset a, Offset c, Offset b, ArrowStyle style, Color color, double w) {
    if ((b - a).distance <= 1) return;
    final towardEnd = (c - b).distance > 0.5 ? c : a;
    final towardStart = (c - a).distance > 0.5 ? c : b;
    final endWidth = style.tapered ? w * 1.8 : w;
    // A tapered body is wider at the head end, but the head stays in proportion to the line
    final end = _head(style.end, b, towardEnd, style.tapered ? w * 1.25 : w, style.headSize.scale);
    final start = _head(style.start, a, towardStart, w, style.headSize.scale);

    final a2 = start.trim, b2 = end.trim;
    final centerline = Path()..moveTo(a2.dx, a2.dy)..quadraticBezierTo(c.dx, c.dy, b2.dx, b2.dy);
    final wedge = style.tapered ? _taperedBody(a2, c, b2, endWidth) : null;
    final taperFull = endWidth * 1.8;

    _styled(canvas, style, color, math.max(1.5, w * 0.35), (paint, extra) {
      if (wedge != null) {
        if (style.pattern == LinePattern.solid) {
          canvas.drawPath(wedge, _fill(paint));
          if (extra > 0) canvas.drawPath(wedge, _stroke(paint, extra * 2));
        } else {
          // A dashed tapered arrow: clip to the wedge and stroke a dashed centerline wide enough to fill it
          canvas.save();
          canvas.clipPath(extra > 0 ? _taperedBody(a2, c, b2, endWidth + extra * 2) : wedge);
          canvas.drawPath(dashed(centerline, style.pattern.dashes(taperFull)), _stroke(paint, taperFull * 1.04 + extra * 2));
          canvas.restore();
        }
      } else {
        canvas.drawPath(dashed(centerline, style.pattern.dashes(w)), _stroke(paint, w + extra * 2));
      }
      for (final part in [start, end]) {
        final path = part.path;
        if (path == null) continue;
        if (part.filled) {
          canvas.drawPath(path, _fill(paint));
          if (extra > 0) canvas.drawPath(path, _stroke(paint, extra * 2));
        } else {
          canvas.drawPath(path, _stroke(paint, part.lineWidth + extra * 2));
        }
      }
    });
  }

  // ---- Other shapes ----

  static Path _smooth(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    if (points.length < 3) {
      path.lineTo(points.last.dx, points.last.dy);
      return path;
    }
    for (var i = 1; i < points.length - 1; i++) {
      final p = points[i], next = points[i + 1];
      path.quadraticBezierTo(p.dx, p.dy, (p.dx + next.dx) / 2, (p.dy + next.dy) / 2);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  static TextPainter _text(String string, Color color, double fontSize, {bool halo = false}) {
    final light = HSVColor.fromColor(color).value > 0.6;
    return TextPainter(
      text: TextSpan(text: string, style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w700,
          shadows: halo ? [Shadow(color: light ? Colors.black.withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.9), blurRadius: 3)] : null)),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// `at` is the text's top-left corner; the box adds padding around it.
  static Rect calloutRect(String string, Offset at, double fontSize) {
    final tp = _text(string, Colors.black, fontSize);
    final padX = fontSize * 0.5, padY = fontSize * 0.3;
    return Rect.fromLTWH(at.dx - padX, at.dy - padY, tp.width + padX * 2, tp.height + padY * 2);
  }

  static void _callout(Canvas canvas, String string, Offset at, Offset? tail, Annotation a) {
    final bubble = calloutPath(calloutRect(string, at, a.fontSize), tail, a.fontSize);
    canvas.drawPath(bubble.shift(const Offset(0, 1)), Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    canvas.drawPath(bubble, Paint()..color = a.color);
    _text(string, contrast(a.color), a.fontSize).paint(canvas, at);
  }

  /// The bubble outline: a rounded box plus a pointer from the box edge facing `tail` to the tail tip.
  static Path calloutPath(Rect box, Offset? tail, double fontSize) {
    final radius = fontSize * 0.35;
    final body = Path()..addRRect(RRect.fromRectXY(box, radius, radius));
    if (tail == null || box.inflate(2).contains(tail)) return body;
    final c = box.center, d = tail - c;
    final halfW = box.width / 2, halfH = box.height / 2;
    final base = math.min(fontSize * 0.9, math.min(box.width, box.height) * 0.6); // pointer width at the box
    final List<Offset> foot;
    if (d.dy.abs() * halfW >= d.dx.abs() * halfH) {
      // Leaves through the top or bottom edge
      final y = d.dy > 0 ? box.bottom - 1 : box.top + 1;
      final x = (c.dx + d.dx * (halfH / d.dy.abs())).clamp(box.left + radius + base / 2, box.right - radius - base / 2);
      foot = [Offset(x - base / 2, y), Offset(x + base / 2, y)];
    } else {
      // Leaves through the left or right edge
      final x = d.dx > 0 ? box.right - 1 : box.left + 1;
      final y = (c.dy + d.dy * (halfW / d.dx.abs())).clamp(box.top + radius + base / 2, box.bottom - radius - base / 2);
      foot = [Offset(x, y - base / 2), Offset(x, y + base / 2)];
    }
    final pointer = Path()..addPolygon([foot[0], tail, foot[1]], true);
    return Path.combine(PathOperation.union, body, pointer);
  }

  static void _step(Canvas canvas, Offset center, int number, Annotation a) {
    final d = a.stepDiameter;
    canvas.drawCircle(center, d / 2, Paint()..color = a.color);
    canvas.drawCircle(center, d / 2, _stroke(Colors.white.withValues(alpha: 0.9), math.max(1.5, d / 16)));
    final tp = TextPainter(
      text: TextSpan(text: '${math.max(number, 1)}',
          style: TextStyle(color: contrast(a.color), fontSize: d * 0.55, fontWeight: FontWeight.w900)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  void _drawSpotlight(Canvas canvas, List<Rect> rects, Rect bounds) {
    final path = Path()..addRect(bounds); // dim the image only, not the canvas area around it
    for (final r in rects) {
      path.addRRect(RRect.fromRectXY(r, 8, 8));
    }
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.55));
  }

  // ---- Selection chrome ----

  void _drawSelection(Canvas canvas, Annotation a) {
    final handles = handlesOf(a);
    if (handles.isEmpty) return;
    final accent = const Color(0xFF2F7CF6);
    final r = a.rect;
    if (r != null) {
      // White under a dashed accent line, so the box shows on light and dark images alike
      final line = 1.5 / scale;
      canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = line);
      canvas.drawPath(dashed(Path()..addRect(r), [5 / scale, 4 / scale]),
          Paint()..color = accent..style = PaintingStyle.stroke..strokeWidth = line);
    }
    final rad = 5 / scale;
    for (var i = 0; i < handles.length; i++) {
      final h = handles[i];
      // The middle handle of an arrow/line (bend) is drawn hollow, like the Swift app
      final bendHandle = a.styleKind == StyleKind.arrow || a.styleKind == StyleKind.line ? i == 2 : false;
      canvas.drawCircle(h, rad + 1 / scale, Paint()..color = Colors.black.withValues(alpha: 0.25));
      canvas.drawCircle(h, rad, Paint()..color = bendHandle ? accent : Colors.white);
      canvas.drawCircle(h, rad, Paint()..color = bendHandle ? Colors.white : accent..style = PaintingStyle.stroke..strokeWidth = 1.5 / scale);
    }
  }

  static List<Offset> handlesOf(Annotation a) {
    switch (a.shape) {
      case ArrowShape(:final from, :final to, :final bend) || LineShape(:final from, :final to, :final bend):
        final mid = Offset((from.dx + to.dx) / 2 + bend.dx, (from.dy + to.dy) / 2 + bend.dy);
        return [from, to, mid];
      case CalloutShape(:final tail?):
        return [tail]; // drag the pointer's tip to re-aim it
      default:
        final r = a.rect;
        if (r == null) return const [];
        return rectHandles(r);
    }
  }

  static List<Offset> rectHandles(Rect r) => [
        r.topLeft, r.topRight, r.bottomLeft, r.bottomRight,
        Offset(r.center.dx, r.top), Offset(r.center.dx, r.bottom),
        Offset(r.left, r.center.dy), Offset(r.right, r.center.dy),
      ];

  @override
  bool shouldRepaint(covariant CanvasPainter old) =>
      old.state != state || old.selectionId != selectionId || old.scale != scale;
}

class _Head {
  final Path? path;
  final bool filled;
  final double lineWidth;
  final Offset trim;
  const _Head(this.path, {this.filled = true, this.lineWidth = 0, required this.trim});
}

/// A small preview of a line style (for the Arrowheads / Pattern menus).
class StylePreview extends StatelessWidget {
  final ArrowStyle style;
  final bool line;
  final Color color;
  const StylePreview(this.style, {super.key, this.line = true, this.color = Colors.black87});

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(48, 18), painter: _PreviewStyle(style, line, color));
}

class _PreviewStyle extends CustomPainter {
  final ArrowStyle style;
  final bool line;
  final Color color;
  _PreviewStyle(this.style, this.line, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final plain = style.copyWith(shadow: false, outline: false);
    final y = size.height / 2;
    if (line) {
      CanvasPainter.drawArrow(canvas, Offset(7, y), Offset(size.width / 2, y), Offset(size.width - 7, y), plain, color, 2);
    } else {
      CanvasPainter.strokeStyled(canvas, Path()..addRRect(RRect.fromRectXY(Rect.fromLTWH(4, 3, size.width - 8, size.height - 6), 2, 2)),
          plain, color, 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewStyle old) => old.style != style || old.line != line || old.color != color;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
