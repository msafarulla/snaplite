import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../editor/canvas_painter.dart';
import '../model/annotation.dart';
import 'gif_encoder.dart';

/// The "build-up" GIF: the original capture, then each annotation appearing in the order it was added,
/// then the finished picture, looping. Rendering uses the editor's own painter; encoding is pure Dart.
class BuildUpGif {
  static const fps = 20;
  static const openingHold = Duration(milliseconds: 1000);
  static const pauseAfterEach = Duration(milliseconds: 400);
  static const finalHold = Duration(milliseconds: 2500);
  static const maxSide = 1600.0;

  /// How long an annotation takes to appear: lines and outlines draw on a bit slower than pops and fades.
  static Duration appearing(Annotation a) => switch (a.shape) {
        ArrowShape() || LineShape() || RectShape() || EllipseShape() || PenShape() => const Duration(milliseconds: 600),
        HighlightShape() => const Duration(milliseconds: 500),
        _ => const Duration(milliseconds: 400),
      };

  /// Output pixels per image pixel: point size (so Retina captures aren't doubled), at most [maxSide] long.
  static double outputScale(CanvasState s) =>
      math.min(1 / s.density, maxSide / math.max(s.image.width, s.image.height)).clamp(0.01, 1.0);

  static Future<Uint8List> render(CanvasState s) async {
    final k = outputScale(s);
    final w = math.max(1, (s.image.width * k).round()), h = math.max(1, (s.image.height * k).round());
    final order = [...s.annotations]..sort((a, b) => a.id.compareTo(b.id)); // the order they were added
    final progress = <int, double>{};
    final frames = <GifFrame>[];
    Uint32List? previous;

    // Each frame keeps only the rectangle that changed; pixels in it that didn't change stay transparent.
    Future<void> frame(Duration delay) async {
      final pixels = await _snapshot(s, progress, k, w, h);
      if (previous == null) {
        frames.add(GifFrame(0, 0, w, h, pixels.buffer.asUint8List(), delay.inMilliseconds));
      } else {
        final changed = _changedRect(previous!, pixels, w, h);
        if (changed == null) {
          frames.last.delayMs += delay.inMilliseconds;
        } else {
          frames.add(_crop(previous!, pixels, w, changed, delay.inMilliseconds));
        }
      }
      previous = pixels;
    }

    await frame(openingHold);
    for (final a in order) {
      final n = math.max(2, appearing(a).inMilliseconds * fps ~/ 1000);
      final step = Duration(microseconds: appearing(a).inMicroseconds ~/ n);
      for (var i = 1; i <= n; i++) {
        progress[a.id] = i / n;
        await frame(step);
      }
      frames.last.delayMs += pauseAfterEach.inMilliseconds;
    }
    frames.last.delayMs += finalHold.inMilliseconds - pauseAfterEach.inMilliseconds;
    return _encodeInBackground(w, h, frames);
  }

  /// A closure of its own, so the isolate gets only the frames (not the canvas and its images).
  static Future<Uint8List> _encodeInBackground(int w, int h, List<GifFrame> frames) =>
      Isolate.run(() => encodeGif(w, h, frames));

  /// One frame as opaque RGBA pixels (transparent canvas areas go on white, since GIF frames here are opaque).
  static Future<Uint32List> _snapshot(CanvasState s, Map<int, double> progress, double k, int w, int h) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    CanvasPainter(state: s, selectionId: null, scale: k, progress: progress).paint(canvas, Size(w.toDouble(), h.toDouble()));
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    return data!.buffer.asUint32List();
  }

  static Rect? _changedRect(Uint32List a, Uint32List b, int w, int h) {
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (a[row + x] != b[row + x]) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    return maxX < 0 ? null : Rect.fromLTRB(minX.toDouble(), minY.toDouble(), maxX + 1.0, maxY + 1.0);
  }

  /// The changed rectangle of `now`, with pixels equal to `before` cleared (alpha 0 = keep the last frame's).
  static GifFrame _crop(Uint32List before, Uint32List now, int w, Rect r, int delayMs) {
    final x0 = r.left.toInt(), y0 = r.top.toInt(), cw = r.width.toInt(), ch = r.height.toInt();
    final out = Uint32List(cw * ch);
    for (var y = 0; y < ch; y++) {
      final src = (y0 + y) * w + x0;
      for (var x = 0; x < cw; x++) {
        final p = now[src + x];
        out[y * cw + x] = p == before[src + x] ? 0 : p;
      }
    }
    return GifFrame(x0, y0, cw, ch, out.buffer.asUint8List(), delayMs);
  }
}
