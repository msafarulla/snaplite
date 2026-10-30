import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../editor/canvas_painter.dart';
import '../model/annotation.dart';

/// Fourier epicycles for the build-up GIF: a chain of spinning circles whose tip traces a stroke as it
/// draws itself on (the Manim Studio effect, without Manim). Arrows, lines, pen strokes, boxes and
/// ellipses qualify.
///
/// The stroke is sampled evenly by length, so the tip at time `along` sits where the drawn-on stroke ends.
/// An open stroke is traced out and back (so the series is continuous) and only the outward half is shown.
class Epicycles {
  final Offset center;
  final List<({double freq, double re, double im})> terms; // largest first
  final bool closed;
  Epicycles._(this.center, this.terms, this.closed);

  static const _samples = 128, _maxCircles = 60;
  static final _cache = Expando<Epicycles>();

  static bool fits(Annotation a) =>
      a.shape is ArrowShape || a.shape is LineShape || a.shape is PenShape || a.shape is RectShape || a.shape is EllipseShape;

  static Epicycles? of(Annotation a) {
    if (!fits(a)) return null;
    return _cache[a.shape] ??= _build(a);
  }

  static Epicycles? _build(Annotation a) {
    final path = CanvasPainter.outlinePath(a);
    final metric = path.computeMetrics().firstOrNull;
    if (metric == null || metric.length < 4) return null;
    Offset at(double f) => metric.getTangentForOffset(metric.length * f)!.position;
    final start = at(0), end = at(1);
    final closed = a.shape is RectShape || a.shape is EllipseShape || (end - start).distance < metric.length * 0.03;
    final pts = closed
        ? [for (var i = 0; i < _samples; i++) at(i / _samples)]
        : [for (var i = 0; i <= _samples; i++) at(i / _samples), for (var i = _samples - 1; i > 0; i--) at(i / _samples)];

    // Discrete Fourier transform of the points as complex numbers
    final n = pts.length;
    final terms = <({double freq, double re, double im})>[];
    for (var k = -n ~/ 2; k < n - n ~/ 2; k++) {
      var re = 0.0, im = 0.0;
      for (var j = 0; j < n; j++) {
        final angle = -2 * math.pi * k * j / n;
        final c = math.cos(angle), s = math.sin(angle);
        re += pts[j].dx * c - pts[j].dy * s;
        im += pts[j].dx * s + pts[j].dy * c;
      }
      terms.add((freq: k.toDouble(), re: re / n, im: im / n));
    }
    final dc = terms.firstWhere((t) => t.freq == 0);
    final rest = terms.where((t) => t.freq != 0).toList()
      ..sort((x, y) => (y.re * y.re + y.im * y.im).compareTo(x.re * x.re + x.im * x.im));
    return Epicycles._(Offset(dc.re, dc.im), rest.take(_maxCircles).toList(), closed);
  }

  /// The circles' centres and the tip at `along` (0…1 of the stroke).
  List<Offset> chain(double along) {
    final s = closed ? along : along / 2;
    final out = [center];
    var p = center;
    for (final t in terms) {
      final angle = 2 * math.pi * t.freq * s;
      final c = math.cos(angle), sn = math.sin(angle);
      p += Offset(t.re * c - t.im * sn, t.re * sn + t.im * c);
      out.add(p);
    }
    return out;
  }

  /// Draws the circles and their arms. `scale` is output pixels per image point, to keep lines thin.
  void paint(Canvas canvas, double along, Color color, double scale) {
    final c = chain(along);
    final hair = 1.2 / scale;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair
      ..color = Colors.white.withValues(alpha: 0.55);
    final arm = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair * 1.4
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.9);
    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair * 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withValues(alpha: 0.35);
    for (var i = 0; i < c.length - 1; i++) {
      final r = (c[i + 1] - c[i]).distance;
      if (r * scale < 1.5) continue; // too small to see
      canvas.drawCircle(c[i], r, ring);
    }
    final arms = Path()..moveTo(c.first.dx, c.first.dy);
    for (final p in c.skip(1)) {
      arms.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(arms, halo);
    canvas.drawPath(arms, arm);
    canvas.drawCircle(c.last, 3 / scale, Paint()..color = color);
    canvas.drawCircle(c.last, 3 / scale, Paint()..style = PaintingStyle.stroke..strokeWidth = hair..color = Colors.white);
  }
}
