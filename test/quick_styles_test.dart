import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/quick_styles.dart';
import 'package:snaplite_flutter/model/annotation.dart';

void main() {
  const mine = ArrowStyle(end: ArrowHead.swept, tapered: true, headSize: HeadSize.large);

  test('the first row is exactly my arrow style, in the theme colours', () {
    final tiles = QuickStyles.presets(QuickKind.arrow, current: mine, size: StrokeSize.large);
    final firstRow = tiles.take(4).toList();
    expect(firstRow.every((q) => q.style == mine && q.size == StrokeSize.large), isTrue);
    expect(firstRow.map((q) => q.color).toSet().length, 4, reason: 'four theme colours');
  });

  test('the other rows use my arrowhead and head size instead of the plain triangle', () {
    final tiles = QuickStyles.presets(QuickKind.arrow, current: mine);
    expect(tiles.where((q) => q.style.end == ArrowHead.triangle), isEmpty, reason: 'no plain triangles left');
    expect(tiles.where((q) => q.style.start == ArrowHead.triangle), isEmpty, reason: 'double-ended uses my head too');
    expect(tiles.every((q) => q.style.headSize == HeadSize.large), isTrue);
    expect(tiles.any((q) => q.style.pattern == LinePattern.dashed), isTrue, reason: 'variations are kept');
    expect(tiles.any((q) => q.style.outline), isTrue);
  });

  test('changing my choice changes the tiles', () {
    final dot = QuickStyles.presets(QuickKind.arrow, current: const ArrowStyle(end: ArrowHead.dot));
    expect(dot.first.style.end, ArrowHead.dot);
    expect(dot.where((q) => q.style.end == ArrowHead.swept && !q.style.outline), isEmpty);
  });
}
