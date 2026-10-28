import 'dart:ui';

/// A smart guide: a line at `at` (x when `vertical`, else y) running from `from` to `to` along the other axis.
class Guide {
  final bool vertical;
  final double at, from, to;
  const Guide(this.vertical, this.at, this.from, this.to);

  @override
  bool operator ==(Object other) =>
      other is Guide && other.vertical == vertical && other.at == at && other.from == from && other.to == to;
  @override
  int get hashCode => Object.hash(vertical, at, from, to);
  @override
  String toString() => 'Guide(${vertical ? 'x' : 'y'}=$at, $from…$to)';
}

/// Snaps a dragged rectangle to `targets` (all in the same coordinates): its left/centre/right edges to
/// theirs, and the same for top/middle/bottom, so images line up or stack edge to edge. Each axis takes
/// the nearest line within `tolerance` (ties: the earlier target and line). Returns how far to shift
/// `moving`, and a guide through every target that lines up after the shift.
(Offset, List<Guide>) snapRect(Rect moving, List<Rect> targets, double tolerance) {
  List<double> xs(Rect r) => [r.left, r.center.dx, r.right];
  List<double> ys(Rect r) => [r.top, r.center.dy, r.bottom];

  double? best(List<double> own, List<double> Function(Rect) lines) {
    double? shift;
    for (final t in targets) {
      for (final line in lines(t)) {
        for (final o in own) {
          final d = line - o;
          if (d.abs() <= tolerance && (shift == null || d.abs() < shift.abs())) shift = d;
        }
      }
    }
    return shift;
  }

  final dx = best(xs(moving), xs) ?? 0, dy = best(ys(moving), ys) ?? 0;
  final r = moving.shift(Offset(dx, dy));
  final guides = <Guide>{};
  const same = 0.5;
  for (final t in targets) {
    for (final line in xs(t)) {
      if (xs(r).any((o) => (o - line).abs() < same)) {
        guides.add(Guide(true, line, r.top < t.top ? r.top : t.top, r.bottom > t.bottom ? r.bottom : t.bottom));
      }
    }
    for (final line in ys(t)) {
      if (ys(r).any((o) => (o - line).abs() < same)) {
        guides.add(Guide(false, line, r.left < t.left ? r.left : t.left, r.right > t.right ? r.right : t.right));
      }
    }
  }
  return (Offset(dx, dy), _merged(guides));
}

/// Guides on the same line become one spanning them all.
List<Guide> _merged(Set<Guide> guides) {
  final byLine = <(bool, double), Guide>{};
  for (final g in guides) {
    final k = (g.vertical, g.at);
    final o = byLine[k];
    byLine[k] = o == null ? g : Guide(g.vertical, g.at, o.from < g.from ? o.from : g.from, o.to > g.to ? o.to : g.to);
  }
  return byLine.values.toList();
}
