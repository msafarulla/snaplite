import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/quick_styles.dart';
import 'package:snaplite_flutter/model/annotation.dart';

void main() {
  const mine = ArrowStyle(end: ArrowHead.swept, tapered: true, headSize: HeadSize.large);
  const red = 0xE8332A;

  test('the first tile is exactly my arrow style, and every tile is in my colour, once', () {
    final tiles = QuickStyles.presets(QuickKind.arrow, color: red, current: mine, size: StrokeSize.large);
    expect(tiles.first.style, mine);
    expect(tiles.first.size, StrokeSize.large);
    expect(tiles.every((q) => q.color == red), isTrue, reason: 'no colour variants');
    expect(tiles.map((q) => (q.size, q.style)).toSet().length, tiles.length, reason: 'each look shown once');
  });

  test('the other tiles use my arrowhead and head size instead of the plain triangle', () {
    final tiles = QuickStyles.presets(QuickKind.arrow, color: red, current: mine);
    expect(tiles.where((q) => q.style.end == ArrowHead.triangle), isEmpty, reason: 'no plain triangles left');
    expect(tiles.where((q) => q.style.start == ArrowHead.triangle), isEmpty, reason: 'double-ended uses my head too');
    expect(tiles.every((q) => q.style.headSize == HeadSize.large), isTrue);
    expect(tiles.any((q) => q.style.pattern == LinePattern.dashed), isTrue, reason: 'variations are kept');
    expect(tiles.any((q) => q.style.outline), isTrue);
  });

  test('changing my choice changes the tiles', () {
    final dot = QuickStyles.presets(QuickKind.arrow, color: red, current: const ArrowStyle(end: ArrowHead.dot));
    expect(dot.first.style.end, ArrowHead.dot);
    expect(dot.where((q) => q.style.end == ArrowHead.swept && !q.style.outline), isEmpty);
  });
}
