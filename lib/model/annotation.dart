import 'dart:ui';


/// The editor tools. Mirrors the Swift app's `Tool`.
enum Tool { select, arrow, line, box, ellipse, highlight, pen, text, callout, step, blur, spotlight, crop, grabText }

enum StrokeSize {
  small,
  medium,
  large;

  String get label => const ['S', 'M', 'L'][index];
  double get line => switch (this) { StrokeSize.small => 3, StrokeSize.medium => 5, StrokeSize.large => 8 };
  double get fontSize => switch (this) { StrokeSize.small => 18, StrokeSize.medium => 26, StrokeSize.large => 36 };
  double get stepDiameter => switch (this) { StrokeSize.small => 26, StrokeSize.medium => 34, StrokeSize.large => 46 };
}

/// Arrowheads, in the Swift app's order (stored as their index).
enum ArrowHead {
  none, triangle, swept, triangleOutline, open, dot, circle, square, diamond, bar;

  String get label => const ['None', 'Triangle', 'Swept', 'Triangle Outline', 'Open', 'Dot', 'Circle', 'Square',
    'Diamond', 'Bar'][index];
}

enum HeadSize {
  small, medium, large;

  String get label => const ['Small', 'Medium', 'Large'][index];
  double get scale => const [0.75, 1.0, 1.45][index];
}

enum LinePattern {
  solid, dashed, dotted, dashDot, longDash;

  String get label => const ['Solid', 'Dashed', 'Dotted', 'Dash-Dot', 'Long Dash'][index];

  /// Dash lengths for a line `w` wide. Near-zero dashes with round caps draw as dots.
  List<double>? dashes(double w) => switch (this) {
        LinePattern.solid => null,
        LinePattern.dashed => [w * 2.4, w * 2.2],
        LinePattern.dotted => [0.01, w * 2],
        LinePattern.dashDot => [w * 2.6, w * 1.8, 0.01, w * 1.8],
        LinePattern.longDash => [w * 5, w * 2.5],
      };
}

/// Which remembered style an annotation or tool uses: arrows, lines, and shapes (box, ellipse, pen).
enum StyleKind {
  arrow, line, shape;

  ArrowStyle get builtIn => switch (this) {
        StyleKind.arrow => ArrowStyle.arrow,
        StyleKind.line => ArrowStyle.line,
        StyleKind.shape => ArrowStyle.shape,
      };

  static StyleKind? ofTool(Tool t) => switch (t) {
        Tool.arrow => StyleKind.arrow,
        Tool.line => StyleKind.line,
        Tool.box || Tool.ellipse || Tool.pen => StyleKind.shape,
        _ => null,
      };
}

/// How arrows, lines, boxes, ellipses and pen strokes are drawn. Heads and tapering only apply to
/// arrows and lines. Mirrors the Swift `ArrowStyle`, including its JSON (shared UserDefaults).
class ArrowStyle {
  final ArrowHead start;
  final ArrowHead end;
  final HeadSize headSize;
  final LinePattern pattern;
  final bool tapered;
  final bool outline;
  final bool shadow;
  const ArrowStyle({
    this.start = ArrowHead.none,
    this.end = ArrowHead.triangle,
    this.headSize = HeadSize.medium,
    this.pattern = LinePattern.solid,
    this.tapered = false,
    this.outline = false,
    this.shadow = true,
  });

  static const arrow = ArrowStyle();
  static const line = ArrowStyle(end: ArrowHead.none);
  static const shape = ArrowStyle(end: ArrowHead.none, shadow: false);

  ArrowStyle copyWith({ArrowHead? start, ArrowHead? end, HeadSize? headSize, LinePattern? pattern, bool? tapered,
          bool? outline, bool? shadow}) =>
      ArrowStyle(
        start: start ?? this.start,
        end: end ?? this.end,
        headSize: headSize ?? this.headSize,
        pattern: pattern ?? this.pattern,
        tapered: tapered ?? this.tapered,
        outline: outline ?? this.outline,
        shadow: shadow ?? this.shadow,
      );

  Map<String, Object> toJson() => {
        'start': start.index, 'end': end.index, 'headSize': headSize.index, 'pattern': pattern.index,
        'tapered': tapered, 'outline': outline, 'shadow': shadow,
      };

  static ArrowStyle? fromJson(Object? json) {
    if (json is! Map) return null;
    T pick<T>(List<T> values, Object? i, T fallback) => i is int && i >= 0 && i < values.length ? values[i] : fallback;
    return ArrowStyle(
      start: pick(ArrowHead.values, json['start'], ArrowHead.none),
      end: pick(ArrowHead.values, json['end'], ArrowHead.triangle),
      headSize: pick(HeadSize.values, json['headSize'], HeadSize.medium),
      pattern: pick(LinePattern.values, json['pattern'], LinePattern.solid),
      tapered: json['tapered'] == true,
      outline: json['outline'] == true,
      shadow: json['shadow'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ArrowStyle && other.start == start && other.end == end && other.headSize == headSize &&
      other.pattern == pattern && other.tapered == tapered && other.outline == outline && other.shadow == shadow;

  @override
  int get hashCode => Object.hash(start, end, headSize, pattern, tapered, outline, shadow);
}

/// The geometry of an annotation, in the base image's coordinate space (origin top-left).
/// A Dart 3 sealed class, so the painter/hit-tester switch over it exhaustively.
sealed class Shape {
  const Shape();
}

class ArrowShape extends Shape {
  final Offset from, to;
  final Offset bend; // how far the mid control point is pulled off the straight line
  const ArrowShape(this.from, this.to, {this.bend = Offset.zero});
}

class LineShape extends Shape {
  final Offset from, to;
  final Offset bend;
  const LineShape(this.from, this.to, {this.bend = Offset.zero});
}

class RectShape extends Shape {
  final Rect rect;
  const RectShape(this.rect);
}

class EllipseShape extends Shape {
  final Rect rect;
  const EllipseShape(this.rect);
}

class HighlightShape extends Shape {
  final Rect rect;
  const HighlightShape(this.rect);
}

class SpotlightShape extends Shape {
  final Rect rect;
  const SpotlightShape(this.rect);
}

class PenShape extends Shape {
  final List<Offset> points;
  const PenShape(this.points);
}

class TextShape extends Shape {
  final String string;
  final Offset at;
  const TextShape(this.string, this.at);
}

/// A speech bubble: text at `at` (top-left of the text) and a pointer whose tip is at `tail`
/// (null: no pointer, e.g. callouts made before pointers existed).
class CalloutShape extends Shape {
  final String string;
  final Offset at;
  final Offset? tail;
  const CalloutShape(this.string, this.at, {this.tail});
}

class StepShape extends Shape {
  final Offset center;
  const StepShape(this.center);
}

/// A pixelated patch cut from the base image (computed when the blur is created/moved).
class BlurShape extends Shape {
  final Rect rect;
  final Image? patch;
  const BlurShape(this.rect, this.patch);
}

/// An image dropped on top: movable, resizable; grows the canvas if it spills past an edge.
class ImageShape extends Shape {
  final Rect rect;
  final Image image;
  const ImageShape(this.rect, this.image);
}

/// A single annotation: geometry plus style.
class Annotation {
  final int id;
  final Shape shape;
  final Color color;
  final StrokeSize size;
  final ArrowStyle arrowStyle;
  /// Pixels per point of the image it was drawn on (2 on Retina captures), so S/M/L look the same
  /// on any capture, as they did in the Swift app (which worked in points).
  final double scale;

  const Annotation({
    required this.id,
    required this.shape,
    this.color = const Color(0xFFE8332A),
    this.size = StrokeSize.medium,
    this.arrowStyle = const ArrowStyle(),
    this.scale = 1,
  });

  double get lineWidth => size.line * scale;
  double get fontSize => size.fontSize * scale;
  double get stepDiameter => size.stepDiameter * scale;

  Annotation copyWith({Shape? shape, Color? color, StrokeSize? size, ArrowStyle? arrowStyle}) => Annotation(
        id: id,
        shape: shape ?? this.shape,
        color: color ?? this.color,
        size: size ?? this.size,
        arrowStyle: arrowStyle ?? this.arrowStyle,
        scale: scale,
      );

  /// Arrows, lines and shapes have a line style; text, steps, blur etc. don't.
  StyleKind? get styleKind => switch (shape) {
        ArrowShape() => StyleKind.arrow,
        LineShape() => StyleKind.line,
        RectShape() || EllipseShape() || PenShape() => StyleKind.shape,
        _ => null,
      };

  /// The rect for rect-based shapes, else null.
  Rect? get rect => switch (shape) {
        RectShape(:final rect) => rect,
        EllipseShape(:final rect) => rect,
        HighlightShape(:final rect) => rect,
        SpotlightShape(:final rect) => rect,
        BlurShape(:final rect) => rect,
        ImageShape(:final rect) => rect,
        _ => null,
      };

  Annotation withRect(Rect r) {
    final s = switch (shape) {
      RectShape() => RectShape(r),
      EllipseShape() => EllipseShape(r),
      HighlightShape() => HighlightShape(r),
      SpotlightShape() => SpotlightShape(r),
      BlurShape(:final patch) => BlurShape(r, patch),
      ImageShape(:final image) => ImageShape(r, image),
      _ => shape,
    };
    return copyWith(shape: s);
  }

  Annotation movedBy(Offset d) {
    final s = switch (shape) {
      ArrowShape(:final from, :final to, :final bend) => ArrowShape(from + d, to + d, bend: bend),
      LineShape(:final from, :final to, :final bend) => LineShape(from + d, to + d, bend: bend),
      PenShape(:final points) => PenShape([for (final p in points) p + d]),
      TextShape(:final string, :final at) => TextShape(string, at + d),
      CalloutShape(:final string, :final at, :final tail) => CalloutShape(string, at + d, tail: tail == null ? null : tail + d),
      StepShape(:final center) => StepShape(center + d),
      _ => (rect != null) ? null : shape,
    };
    if (s == null) return withRect(rect!.shift(d));
    return copyWith(shape: s);
  }
}

/// The editable document: a base image plus annotations, all in image points.
class CanvasState {
  final Image image;
  final List<Annotation> annotations;
  /// Shows through transparent parts of the image, including space added by resizing or auto-grow.
  final Color background;
  /// Pixels per point (2 for Retina captures); new annotations are sized by it.
  final double density;
  const CanvasState({required this.image, this.annotations = const [], this.background = const Color(0xFFFFFFFF),
      this.density = 1});

  CanvasState copyWith({Image? image, List<Annotation>? annotations, Color? background}) => CanvasState(
      image: image ?? this.image, annotations: annotations ?? this.annotations, background: background ?? this.background,
      density: density);
}
