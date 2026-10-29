import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// A Manim Studio project: a 16:9 stage (Manim's 14.222 × 8 frame, origin in the middle, y up) holding
/// objects that appear one after another in timeline order. Saved as JSON (.snapmanim), images included,
/// so a project still works after it's moved. [code] turns it into a Manim Community scene.
class ManimDoc {
  static const frameW = 128 / 9, frameH = 8.0; // 14.222 × 8
  static const className = 'SnapStudio';

  Color background;
  bool fadeOutAtEnd;
  double endHold;
  final List<MItem> items; // timeline order
  int _nextId;

  ManimDoc({this.background = const Color(0xFF000000), this.fadeOutAtEnd = true, this.endHold = 2, List<MItem>? items})
      : items = items ?? [],
        _nextId = (items ?? []).fold(0, (m, i) => math.max(m, i.id)) + 1;

  int newId() => _nextId++;

  Map<String, Object?> toJson() => {
        'format': 'snapnow-manim', 'version': 1,
        'background': background.toARGB32(), 'fadeOutAtEnd': fadeOutAtEnd, 'endHold': endHold,
        'items': [for (final i in items) i.toJson()],
      };

  static ManimDoc fromJson(Map<String, dynamic> j) => ManimDoc(
        background: Color(j['background'] as int? ?? 0xFF000000),
        fadeOutAtEnd: j['fadeOutAtEnd'] != false,
        endHold: (j['endHold'] as num?)?.toDouble() ?? 2,
        items: [for (final i in (j['items'] as List? ?? const [])) ?MItem.fromJson(i as Map<String, dynamic>)],
      );

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
  static ManimDoc decode(String s) => fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// Images the scene needs beside it (file name → bytes).
  Map<String, List<int>> get files => {
        for (final i in items)
          if (i.kind == MKind.image && i.image != null) 'image_${i.id}.png': i.image!,
      };

  bool get usesMath => items.any((i) => i.kind == MKind.math);

  /// The text or math object a "Transform from previous" morphs from: the nearest one before `index`.
  int? transformSource(int index) {
    for (var j = index - 1; j >= 0; j--) {
      if (items[j].kind == MKind.text || items[j].kind == MKind.math) return j;
    }
    return null;
  }

  /// The Python source (Manim Community). Strings are JSON-escaped literals, LaTeX raw strings with quotes
  /// escaped, and graph formulas only pass [Formula.toPython] (math only), so no other Python gets in.
  /// `latex`: whether LaTeX is installed; without it graphs leave out their axis numbers (Manim sets
  /// numbers with LaTeX).
  String code({bool latex = true}) {
    String n(double v) => v.toStringAsFixed(3);
    String p(Offset o) => '[${n(o.dx)}, ${n(o.dy)}, 0]';
    final out = StringBuffer()
      ..writeln('# Made with SnapNow Manim Studio. Edit freely, or keep editing on the stage.')
      ..writeln('from manim import *')
      ..writeln('from math import *')
      ..writeln()
      ..writeln()
      ..writeln('class $className(Scene):')
      ..writeln('    def construct(self):')
      ..writeln('        self.camera.background_color = ${_hex(background)}');
    final removed = <int>{}; // replaced by a transform
    for (var idx = 0; idx < items.length; idx++) {
      final i = items[idx];
      final v = 'm${i.id}';
      final c = _hex(i.color);
      final lines = <String>[];
      switch (i.kind) {
        case MKind.text:
          lines.add('$v = Text(${jsonEncode(i.text)}, font=${jsonEncode(i.font)}, font_size=${n(i.fontSize)}, color=$c)'
              '.move_to(${p(i.pos)})');
        case MKind.math:
          lines.add('$v = MathTex(r"${_latex(i.text)}", font_size=${n(i.fontSize)}, color=$c).move_to(${p(i.pos)})');
        case MKind.rect:
          lines.add('$v = Rectangle(width=${n(i.size.width)}, height=${n(i.size.height)}, color=$c, '
              'stroke_width=${n(i.stroke)}, fill_color=$c, fill_opacity=${n(i.fill)}).move_to(${p(i.pos)})');
        case MKind.circle:
          lines.add('$v = Ellipse(width=${n(i.size.width)}, height=${n(i.size.height)}, color=$c, '
              'stroke_width=${n(i.stroke)}, fill_color=$c, fill_opacity=${n(i.fill)}).move_to(${p(i.pos)})');
        case MKind.arrow:
          lines.add('$v = Arrow(${p(i.pos)}, ${p(i.end)}, buff=0, color=$c, stroke_width=${n(i.stroke)})');
        case MKind.line:
          lines.add('$v = Line(${p(i.pos)}, ${p(i.end)}, color=$c, stroke_width=${n(i.stroke)})');
        case MKind.dot:
          lines.add('$v = Dot(${p(i.pos)}, radius=${n(i.size.width / 2)}, color=$c)');
        case MKind.graph:
          final f = Formula.toPython(i.text) ?? 'x';
          final g = i.graph;
          lines.add('${v}_axes = Axes(x_range=[${n(g.xMin)}, ${n(g.xMax)}, ${n(g.xStep)}], '
              'y_range=[${n(g.yMin)}, ${n(g.yMax)}, ${n(g.yStep)}], x_length=${n(i.size.width)}, '
              'y_length=${n(i.size.height)}, tips=False, axis_config={"include_numbers": ${latex ? 'True' : 'False'}, "font_size": 20})'
              '.move_to(${p(i.pos)})');
          // Manim doesn't clip a plot to the axes, so only the stretches of x where y stays in range are drawn
          final runs = _inRange(i.text, g);
          lines.add('${v}_plot = VGroup(${[
            for (final (a, b) in runs)
              '${v}_axes.plot(lambda x: $f, x_range=[${n(a)}, ${n(b)}], color=$c, stroke_width=${n(i.stroke)})'
          ].join(', ')})');
          lines.add('$v = VGroup(${v}_axes, ${v}_plot)');
        case MKind.image:
          lines.add('$v = ImageMobject("image_${i.id}.png").scale_to_fit_width(${n(i.size.width)}).move_to(${p(i.pos)})');
      }
      final run = 'run_time=${n(i.runTime)}';
      String? play;
      final src = i.enter == MEnter.transform ? transformSource(idx) : null;
      if (src != null) {
        play = 'ReplacementTransform(m${items[src].id}, $v)';
        removed.add(items[src].id);
      } else {
        play = switch (i.enter) {
          MEnter.write => i.kind == MKind.image ? 'FadeIn($v)' : 'Write($v)',
          MEnter.create => i.kind == MKind.graph ? 'Create(${v}_axes), Create(${v}_plot)'
              : i.kind == MKind.image ? 'FadeIn($v)' : 'Create($v)',
          MEnter.fadeIn || MEnter.transform => 'FadeIn($v, shift=UP * 0.3)',
          MEnter.grow => 'GrowFromCenter($v)',
          MEnter.drawBorder => i.kind == MKind.image ? 'FadeIn($v)' : 'DrawBorderThenFill($v)',
          MEnter.none => null,
        };
      }
      out..writeln()..writeln('        # ${i.label}');
      for (final l in lines) {
        out.writeln('        $l');
      }
      out.writeln(play == null ? '        self.add($v)' : '        self.play($play, $run)');
      final emph = switch (i.emphasis) {
        MEmphasis.indicate => 'Indicate($v)',
        MEmphasis.circumscribe => i.kind == MKind.image ? null : 'Circumscribe($v)',
        MEmphasis.wiggle => 'Wiggle($v)',
        MEmphasis.none => null,
      };
      if (emph != null) out.writeln('        self.play($emph)');
      if (i.wait > 0) out.writeln('        self.wait(${n(i.wait)})');
    }
    out.writeln();
    final shown = [for (final i in items) if (!removed.contains(i.id)) 'm${i.id}'];
    if (fadeOutAtEnd && shown.isNotEmpty) {
      if (endHold > 0) out.writeln('        self.wait(${n(endHold)})');
      out.writeln('        self.play(*[FadeOut(m) for m in [${shown.join(', ')}]])');
    } else {
      out.writeln('        self.wait(${n(math.max(endHold, 0.1))})');
    }
    return out.toString();
  }

  /// The stretches of x (from, to) where the formula is defined and inside the y range.
  static List<(double, double)> _inRange(String formula, MGraph g) {
    const steps = 400;
    final runs = <(double, double)>[];
    double? start;
    double last = g.xMin;
    for (var k = 0; k <= steps; k++) {
      final x = g.xMin + (g.xMax - g.xMin) * k / steps;
      final y = Formula.eval(formula, x);
      final inside = y != null && y >= g.yMin && y <= g.yMax;
      if (inside) {
        start ??= x;
        last = x;
      } else if (start != null) {
        if (last > start) runs.add((start, last));
        start = null;
      }
    }
    if (start != null && last > start) runs.add((start, last));
    return runs;
  }

  static String _hex(Color c) => '"#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}"';

  /// LaTeX inside a Python raw string r"…": a quote can't be escaped there (it becomes two single quotes),
  /// and a trailing backslash would swallow the closing quote (a space goes after it).
  static String _latex(String s) {
    var t = s.replaceAll('"', "''").replaceAll('\n', ' ');
    var trailing = 0;
    while (trailing < t.length && t[t.length - 1 - trailing] == r'\') {
      trailing++;
    }
    if (trailing.isOdd) t = '$t ';
    return t;
  }
}

enum MKind {
  text('Text'), math('Math'), rect('Rectangle'), circle('Circle'), arrow('Arrow'), line('Line'), dot('Dot'),
  graph('Graph'), image('Image');

  final String label;
  const MKind(this.label);
}

enum MEnter {
  write('Write'), create('Create'), fadeIn('Fade In'), grow('Grow'), drawBorder('Draw Border, Then Fill'),
  transform('Transform from Previous'), none('Appear');

  final String label;
  const MEnter(this.label);
}

enum MEmphasis {
  none('None'), indicate('Indicate'), circumscribe('Circumscribe'), wiggle('Wiggle');

  final String label;
  const MEmphasis(this.label);
}

class MGraph {
  final double xMin, xMax, xStep, yMin, yMax, yStep;
  const MGraph({this.xMin = -4, this.xMax = 4, this.xStep = 1, this.yMin = -2, this.yMax = 4, this.yStep = 1});

  Map<String, Object> toJson() => {'xMin': xMin, 'xMax': xMax, 'xStep': xStep, 'yMin': yMin, 'yMax': yMax, 'yStep': yStep};
  static MGraph fromJson(Map<String, dynamic>? j) {
    double g(String k, double d) => (j?[k] as num?)?.toDouble() ?? d;
    return MGraph(xMin: g('xMin', -4), xMax: g('xMax', 4), xStep: g('xStep', 1), yMin: g('yMin', -2), yMax: g('yMax', 4),
        yStep: g('yStep', 1));
  }

  MGraph copyWith({double? xMin, double? xMax, double? yMin, double? yMax}) => MGraph(
      xMin: xMin ?? this.xMin, xMax: xMax ?? this.xMax, xStep: xStep, yMin: yMin ?? this.yMin, yMax: yMax ?? this.yMax,
      yStep: yStep);
}

/// One object on the stage. Positions and sizes are in scene units (the frame is 14.222 × 8).
class MItem {
  final int id;
  MKind kind;
  Offset pos; // centre (arrow / line: start)
  Offset end; // arrow / line end
  Size size; // rect / circle / graph / image width × height; dot: diameter
  String text; // text, LaTeX, or the graph's formula
  String font;
  double fontSize;
  Color color;
  double fill; // 0…1
  double stroke;
  MGraph graph;
  Uint8List? image;
  MEnter enter;
  MEmphasis emphasis;
  double runTime, wait;

  MItem({
    required this.id,
    required this.kind,
    this.pos = Offset.zero,
    this.end = const Offset(2, 0),
    this.size = const Size(3, 2),
    this.text = '',
    this.font = 'Helvetica Neue',
    this.fontSize = 48,
    this.color = const Color(0xFFFFFFFF),
    this.fill = 0,
    this.stroke = 4,
    this.graph = const MGraph(),
    this.image,
    MEnter? enter,
    this.emphasis = MEmphasis.none,
    this.runTime = 1,
    this.wait = 0.5,
  }) : enter = enter ?? _defaultEnter(kind);

  static MEnter _defaultEnter(MKind k) => switch (k) {
        MKind.text || MKind.math => MEnter.write,
        MKind.dot => MEnter.grow,
        MKind.image => MEnter.fadeIn,
        _ => MEnter.create,
      };

  /// For the timeline and the comment above the object in the code: one line, no control characters
  /// (a carriage return would end a Python comment), and a formula only once it passes the check.
  String get label {
    final l = switch (kind) {
      MKind.text || MKind.math => '${kind.label}: ${text.split('\n').first}',
      MKind.graph => Formula.toPython(text) == null ? 'Graph (formula not valid)' : 'Graph: y = $text',
      _ => kind.label,
    };
    return l.replaceAll(RegExp(r'[\x00-\x1f\x7f\u0085\u2028\u2029]'), ' ');
  }

  Map<String, Object?> toJson() => {
        'id': id, 'kind': kind.name, 'pos': [pos.dx, pos.dy], 'end': [end.dx, end.dy], 'size': [size.width, size.height],
        'text': text, 'font': font, 'fontSize': fontSize, 'color': color.toARGB32(), 'fill': fill, 'stroke': stroke,
        'graph': graph.toJson(), if (image != null) 'image': base64Encode(image!),
        'enter': enter.name, 'emphasis': emphasis.name, 'runTime': runTime, 'wait': wait,
      };

  static MItem? fromJson(Map<String, dynamic> j) {
    final kind = MKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null || j['id'] is! int) return null;
    Offset o(Object? v, Offset d) => v is List && v.length == 2 ? Offset((v[0] as num).toDouble(), (v[1] as num).toDouble()) : d;
    final sz = j['size'];
    return MItem(
      id: j['id'] as int,
      kind: kind,
      pos: o(j['pos'], Offset.zero),
      end: o(j['end'], const Offset(2, 0)),
      size: sz is List && sz.length == 2 ? Size((sz[0] as num).toDouble(), (sz[1] as num).toDouble()) : const Size(3, 2),
      text: j['text'] as String? ?? '',
      font: j['font'] as String? ?? 'Helvetica Neue',
      fontSize: (j['fontSize'] as num?)?.toDouble() ?? 48,
      color: Color(j['color'] as int? ?? 0xFFFFFFFF),
      fill: (j['fill'] as num?)?.toDouble() ?? 0,
      stroke: (j['stroke'] as num?)?.toDouble() ?? 4,
      graph: MGraph.fromJson(j['graph'] as Map<String, dynamic>?),
      image: j['image'] is String ? base64Decode(j['image'] as String) : null,
      enter: MEnter.values.where((e) => e.name == j['enter']).firstOrNull,
      emphasis: MEmphasis.values.where((e) => e.name == j['emphasis']).firstOrNull ?? MEmphasis.none,
      runTime: (j['runTime'] as num?)?.toDouble() ?? 1,
      wait: (j['wait'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// Graph formulas like `x^2 - 1` or `2*sin(x)`: checked here (numbers, x, + - * / ^, parentheses and a few
/// functions only), evaluated for the stage preview, and written out as Python for Manim.
class Formula {
  static const functions = {'sin', 'cos', 'tan', 'exp', 'log', 'sqrt', 'abs', 'asin', 'acos', 'atan'};
  static const constants = {'pi', 'e'};

  /// Tokens, or null if anything else appears.
  static List<String>? _tokens(String s) {
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ') { i++; continue; }
      if ('+-*/^()'.contains(ch)) { out.add(ch); i++; continue; }
      final num = RegExp(r'\d+(\.\d+)?|\.\d+').matchAsPrefix(s, i);
      if (num != null) { out.add(num.group(0)!); i = num.end; continue; }
      final word = RegExp(r'[a-z]+').matchAsPrefix(s, i);
      if (word != null) {
        final w = word.group(0)!;
        if (w != 'x' && !functions.contains(w) && !constants.contains(w)) return null;
        out.add(w); i = word.end; continue;
      }
      return null;
    }
    return out;
  }

  /// The formula as a Python expression in x, or null when it isn't valid.
  static String? toPython(String s) {
    final t = _tokens(s.trim());
    if (t == null || t.isEmpty || eval(s, 0.5) == null && eval(s, 1.5) == null) return null;
    return t.map((x) => x == '^' ? '**' : x).join(' ');
  }

  /// The value at x (null if the formula is invalid or undefined there).
  static double? eval(String s, double x) {
    final t = _tokens(s.trim());
    if (t == null || t.isEmpty) return null;
    final p = _Parser(t, x);
    final v = p.expr();
    if (p.i != t.length || v == null || v.isNaN || v.isInfinite) return null;
    return v;
  }
}

/// Recursive descent over [Formula] tokens, with Python's precedence (so -x^2 = -(x^2)):
/// expr = term (± term)*, term = unary (*/ unary)*, unary = ± unary | power, power = atom (^ unary)?,
/// atom = number | x | pi | e | f(atom) | (expr).
class _Parser {
  final List<String> t;
  final double x;
  int i = 0;
  _Parser(this.t, this.x);

  double? expr() {
    var v = term();
    while (v != null && i < t.length && (t[i] == '+' || t[i] == '-')) {
      final op = t[i++];
      final r = term();
      if (r == null) return null;
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double? term() {
    var v = unary();
    while (v != null && i < t.length && (t[i] == '*' || t[i] == '/')) {
      final op = t[i++];
      final r = unary();
      if (r == null) return null;
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  double? power() {
    final base = atom();
    if (base != null && i < t.length && t[i] == '^') {
      i++;
      final ex = unary(); // right-associative, and 2^-1 works
      return ex == null ? null : math.pow(base, ex).toDouble();
    }
    return base;
  }

  double? unary() {
    if (i < t.length && t[i] == '-') {
      i++;
      final v = unary();
      return v == null ? null : -v;
    }
    if (i < t.length && t[i] == '+') {
      i++;
      return unary();
    }
    return power();
  }

  double? atom() {
    if (i >= t.length) return null;
    final tok = t[i++];
    if (tok == '(') {
      final v = expr();
      if (i >= t.length || t[i] != ')') return null;
      i++;
      return v;
    }
    if (tok == 'x') return x;
    if (tok == 'pi') return math.pi;
    if (tok == 'e') return math.e;
    if (Formula.functions.contains(tok)) {
      if (i >= t.length || t[i] != '(') return null;
      final a = atom();
      if (a == null) return null;
      return switch (tok) {
        'sin' => math.sin(a), 'cos' => math.cos(a), 'tan' => math.tan(a), 'exp' => math.exp(a),
        'log' => math.log(a), 'sqrt' => math.sqrt(a), 'abs' => a.abs(), 'asin' => math.asin(a),
        'acos' => math.acos(a), _ => math.atan(a),
      };
    }
    return double.tryParse(tok);
  }
}
