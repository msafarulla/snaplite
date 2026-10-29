import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/model/annotation.dart';

void main() {
  test('Border is saved with the style (and older styles load without it)', () {
    const style = ArrowStyle(border: true);
    expect(ArrowStyle.fromJson(style.toJson())!.border, isTrue);
    expect(ArrowStyle.fromJson(const ArrowStyle().toJson())!.border, isFalse);
    expect(style.withWidth(12).border, isTrue, reason: 'the thickness slider keeps it');
  });

  test('the edge is a darker shade of the same colour', () {
    const blue = Color(0xFF2F6BFF);
    final edge = CanvasPainter.darker(blue);
    expect(HSLColor.fromColor(edge).lightness, lessThan(HSLColor.fromColor(blue).lightness));
    expect((HSLColor.fromColor(edge).hue - HSLColor.fromColor(blue).hue).abs(), lessThan(2));
    expect(CanvasPainter.darker(Colors.black), isNot(Colors.black), reason: 'still visible on black');
  });

  test('a bordered line has the darker colour along its edge', () async {
    const red = Color(0xFFFF3B30);
    final r = ui.PictureRecorder();
    final canvas = Canvas(r)..drawColor(Colors.white, BlendMode.src);
    CanvasPainter.strokeStyled(canvas, Path()..moveTo(20, 40)..lineTo(180, 40), const ArrowStyle(end: ArrowHead.none, border: true, shadow: false), red, 16);
    final img = await r.endRecording().toImage(200, 80);
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
    Color at(int x, int y) { final i = (y * 200 + x) * 4; return Color.fromARGB(px[i + 3], px[i], px[i + 1], px[i + 2]); }
    expect(at(100, 40 - 5).toARGB32(), red.toARGB32(), reason: 'the body is the line colour');
    expect(HSLColor.fromColor(at(100, 40)).lightness, greaterThan(HSLColor.fromColor(red).lightness), reason: 'a lighter shine down the middle');
    final edge = at(100, 40 - 9); // just outside the 16-wide line, inside the border
    expect(HSLColor.fromColor(edge).lightness, lessThan(HSLColor.fromColor(red).lightness - 0.1), reason: 'darker edge');
  });
}
