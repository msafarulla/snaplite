import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// A Manim Studio project: a 16:9 stage (Manim's 14.222 × 8 frame, origin in the middle, y up) holding
/// objects that play in timeline order (or together with the one before). Saved as JSON (.snapmanim),
/// images included, so a project still works after it's moved. [code] turns it into a Manim Community scene.
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
        'format': 'snapnow-manim', 'version': 2,
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

  bool get usesMath => items.any((i) => i.kind == MKind.math || (i.kind == MKind.brace && i.text.isNotEmpty && i.braceMath));

  /// The object a Transform morphs from: the nearest earlier one still on screen (not a brace's own).
  int? transformSource(int index) {
    for (var j = index - 1; j >= 0; j--) {
      if (items[j].exit == MExit.none) return j;
    }
    return null;
  }

  /// What a Brace wraps: the nearest earlier object that isn't a brace.
  int? braceTarget(int index) {
    for (var j = index - 1; j >= 0; j--) {
      if (items[j].kind != MKind.brace) return j;
    }
    return null;
  }

  bool get usesCamera => items.any((i) => i.zoom);

  /// The Python source (Manim Community). Strings are JSON-escaped literals, LaTeX raw strings with quotes
  /// escaped, and graph formulas only pass [Formula.toPython] (math only), so no other Python gets in.
  /// `latex`: whether LaTeX is installed; without it graphs and number lines leave out their numbers (Manim
  /// sets numbers with LaTeX).
  String code({bool latex = true}) {
    String n(double v) => v.toStringAsFixed(3);
    String p(Offset o) => '[${n(o.dx)}, ${n(o.dy)}, 0]';
    final camera = usesCamera;
    final out = StringBuffer()
      ..writeln('# Made with SnapNow Manim Studio. Edit freely, or keep editing on the stage.')
      ..writeln('from manim import *')
      ..writeln('from math import *')
      ..writeln();
    if (items.any((i) => i.kind == MKind.path && i.enter == MEnter.fourier)) out.write(_fourierHelper);
    out
      ..writeln()
      ..writeln('class $className(${camera ? 'MovingCameraScene' : 'Scene'}):')
      ..writeln('    def construct(self):')
      ..writeln('        self.camera.background_color = ${_hex(background)}');
    if (camera) out.writeln('        self.camera.frame.save_state()');

    final gone = <int>{}; // replaced by a transform, or exited
    // Objects that start together (the first, then each "with previous" after it) play as one group
    final groups = <List<int>>[];
    for (var idx = 0; idx < items.length; idx++) {
      if (items[idx].withPrevious && groups.isNotEmpty) {
        groups.last.add(idx);
      } else {
        groups.add([idx]);
      }
    }

    for (final group in groups) {
      final enters = <String>[];
      final traceDots = <String>[];
      var runTime = 0.0;
      for (final idx in group) {
        final i = items[idx];
        final v = 'm${i.id}';
        out..writeln()..writeln('        # ${i.label}');
        for (final l in _build(i, idx, v, n, p, latex)) {
          out.writeln('        $l');
        }
        if (i.zoom) {
          out.writeln('        self.play(self.camera.frame.animate.set(width=max($v.width * 2.2, 5)).move_to($v), run_time=0.8)');
        }
        final src = (i.enter == MEnter.transform || i.enter == MEnter.fadeTransform) ? transformSource(idx) : null;
        final anim = src != null
            ? '${i.enter == MEnter.transform ? 'ReplacementTransform' : 'FadeTransform'}(m${items[src].id}, $v)'
            : _enter(i, v);
        if (src != null) gone.add(items[src].id);
        if (i.enter == MEnter.fourier && i.kind == MKind.path && i.points.length >= 2) {
          // Circles on circles trace the drawing, then hand over to the drawing itself (arrowhead and all)
          out
            ..writeln('        ${v}_trace = snapnow_fourier(self, $v, ${i.fourierN}, ${n(i.runTime)}, ${_hex(i.color)}, '
                '${n(i.stroke)}, ${i.closed ? 'True' : 'False'}, ${i.showCircles ? 'True' : 'False'})')
            ..writeln('        self.play(FadeTransform(${v}_trace, $v), run_time=0.4)');
          continue;
        }
        if (i.enter == MEnter.traceDot && i.kind != MKind.image) {
          out.writeln('        ${v}_dot = Dot(radius=0.08, color=${_hex(i.color)}).set_glow_factor(1)');
          traceDots.add('${v}_dot');
        }
        if (anim == null) {
          out.writeln('        self.add($v)');
        } else {
          enters.add('$anim${_rate(i)}');
          runTime = math.max(runTime, i.runTime);
        }
      }
      if (enters.isNotEmpty) out.writeln('        self.play(${enters.join(', ')}, run_time=${n(runTime)})');
      if (traceDots.isNotEmpty) out.writeln('        self.play(${[for (final d in traceDots) 'FadeOut($d)'].join(', ')}, run_time=0.3)');
      var wait = 0.0;
      for (final idx in group) {
        final i = items[idx];
        final v = 'm${i.id}';
        final emph = _emphasis(i, v);
        if (emph != null) out.writeln('        self.play($emph)');
        final move = _motion(i, v, n);
        if (move != null) out.writeln('        self.play($move, run_time=${n(i.runTime)}${_rate(i)})');
        wait = math.max(wait, i.wait);
      }
      if (wait > 0) out.writeln('        self.wait(${n(wait)})');
      // A zoom is for that object's moment: the camera goes back to the whole frame before the next one
      if (group.any((idx) => items[idx].zoom)) out.writeln('        self.play(Restore(self.camera.frame), run_time=0.8)');
      final exits = [
        for (final idx in group)
          if (_exit(items[idx], 'm${items[idx].id}') case final e?) e,
      ];
      for (final idx in group) {
        if (items[idx].exit != MExit.none) gone.add(items[idx].id);
      }
      if (exits.isNotEmpty) out.writeln('        self.play(${exits.join(', ')})');
    }

    out.writeln();
    final shown = [for (final i in items) if (!gone.contains(i.id)) 'm${i.id}'];
    if (fadeOutAtEnd && shown.isNotEmpty) {
      if (endHold > 0) out.writeln('        self.wait(${n(endHold)})');
      out.writeln('        self.play(*[FadeOut(m) for m in [${shown.join(', ')}]])');
    } else {
      out.writeln('        self.wait(${n(math.max(endHold, 0.1))})');
    }
    return out.toString();
  }

  /// The lines that create object `i` as variable `v`.
  List<String> _build(MItem i, int idx, String v, String Function(double) n, String Function(Offset) p, bool latex) {
    final c = _hex(i.color);
    final style = 'color=$c, stroke_width=${n(i.stroke)}, fill_color=$c, fill_opacity=${n(i.fill)}';
    final deg = i.curve * math.pi / 180;
    switch (i.kind) {
      case MKind.text:
        return ['$v = Text(${jsonEncode(i.text)}, font=${jsonEncode(i.font)}, font_size=${n(i.fontSize)}, color=$c)'
            '.move_to(${p(i.pos)})'];
      case MKind.math:
        return ['$v = MathTex(r"${_latex(i.text)}", font_size=${n(i.fontSize)}, color=$c).move_to(${p(i.pos)})'];
      case MKind.rect:
        return ['$v = Rectangle(width=${n(i.size.width)}, height=${n(i.size.height)}, $style).move_to(${p(i.pos)})'];
      case MKind.circle:
        return ['$v = Ellipse(width=${n(i.size.width)}, height=${n(i.size.height)}, $style).move_to(${p(i.pos)})'];
      case MKind.triangle:
        return ['$v = Triangle($style).stretch_to_fit_width(${n(i.size.width)}).stretch_to_fit_height(${n(i.size.height)})'
            '.move_to(${p(i.pos)})'];
      case MKind.polygon:
        return ['$v = RegularPolygon(n=${i.sides}, $style).scale_to_fit_width(${n(i.size.width)}).move_to(${p(i.pos)})'];
      case MKind.star:
        return ['$v = Star(n=${i.sides}, $style).scale_to_fit_width(${n(i.size.width)}).move_to(${p(i.pos)})'];
      case MKind.arrow:
        if (i.curve.abs() < 1) {
          return ['$v = ${i.doubleHead ? 'DoubleArrow' : 'Arrow'}(${p(i.pos)}, ${p(i.end)}, buff=0, color=$c, stroke_width=${n(i.stroke)})'];
        }
        return ['$v = ${i.doubleHead ? 'CurvedDoubleArrow' : 'CurvedArrow'}(${p(i.pos)}, ${p(i.end)}, angle=${n(deg)}, '
            'color=$c, stroke_width=${n(i.stroke)})'];
      case MKind.line:
        if (i.curve.abs() < 1) {
          return ['$v = ${i.dashed ? 'DashedLine' : 'Line'}(${p(i.pos)}, ${p(i.end)}, color=$c, stroke_width=${n(i.stroke)})'];
        }
        final arc = 'ArcBetweenPoints(${p(i.pos)}, ${p(i.end)}, angle=${n(deg)}, color=$c, stroke_width=${n(i.stroke)})';
        return ['$v = ${i.dashed ? 'DashedVMobject($arc)' : arc}'];
      case MKind.dot:
        return ['$v = Dot(${p(i.pos)}, radius=${n(i.size.width / 2)}, color=$c)'];
      case MKind.graph:
        final f = Formula.toPython(i.text) ?? 'x';
        final g = i.graph;
        // Manim doesn't clip a plot to the axes, so only the stretches of x where y stays in range are drawn
        final runs = _inRange(i.text, g);
        return [
          '${v}_axes = Axes(x_range=[${n(g.xMin)}, ${n(g.xMax)}, ${n(g.xStep)}], '
              'y_range=[${n(g.yMin)}, ${n(g.yMax)}, ${n(g.yStep)}], x_length=${n(i.size.width)}, '
              'y_length=${n(i.size.height)}, tips=False, axis_config={"include_numbers": ${latex ? 'True' : 'False'}, "font_size": 20})'
              '.move_to(${p(i.pos)})',
          '${v}_plot = VGroup(${[
            for (final (a, b) in runs)
              '${v}_axes.plot(lambda x: $f, x_range=[${n(a)}, ${n(b)}], color=$c, stroke_width=${n(i.stroke)})'
          ].join(', ')})',
          '$v = VGroup(${v}_axes, ${v}_plot)',
        ];
      case MKind.numberLine:
        final g = i.graph;
        return ['$v = NumberLine(x_range=[${n(g.xMin)}, ${n(g.xMax)}, ${n(g.xStep)}], length=${n(i.size.width)}, '
            'color=$c, include_numbers=${latex ? 'True' : 'False'}).move_to(${p(i.pos)})'];
      case MKind.brace:
        final t = braceTarget(idx);
        final target = t == null ? 'Line(LEFT, RIGHT)' : 'm${items[t].id}';
        final dir = i.braceDir.manim;
        final lines = ['${v}_brace = Brace($target, direction=$dir, color=$c)'];
        if (i.text.isEmpty) {
          lines.add('$v = ${v}_brace');
        } else {
          final label = i.braceMath
              ? 'MathTex(r"${_latex(i.text)}", font_size=${n(i.fontSize)}, color=$c)'
              : 'Text(${jsonEncode(i.text)}, font=${jsonEncode(i.font)}, font_size=${n(i.fontSize)}, color=$c)';
          lines.add('$v = VGroup(${v}_brace, $label.next_to(${v}_brace, $dir))');
        }
        return lines;
      case MKind.path:
        final pts = [for (final q in i.points) i.pos + q];
        if (pts.length < 2) return ['$v = Dot(${p(i.pos)}, radius=0.02, color=$c)'];
        if (i.closed) pts.add(pts.first);
        return [
          '$v = TipableVMobject(color=$c, stroke_width=${n(i.stroke)})',
          '$v.set_points_smoothly([${pts.map(p).join(', ')}])',
          if (i.arrowTip && !i.closed) '$v.add_tip(tip_length=0.25, tip_width=0.25)',
        ];
      case MKind.image:
        return ['$v = ImageMobject("image_${i.id}.png").scale_to_fit_width(${n(i.size.width)}).move_to(${p(i.pos)})'];
    }
  }

  /// The Fourier drawing, 3Blue1Brown style: the path sampled into complex numbers, its discrete Fourier
  /// transform as rotating vectors (largest first, ordered by frequency), drawn tip to tail with their circles
  /// while the last tip leaves a trace. An open path is mirrored so it closes, and only its first half is drawn.
  static const _fourierHelper = '''
def snapnow_fourier(scene, path, n_vectors, run_time, color, stroke_width, closed, show_circles):
    samples = 400
    z = np.array([complex(*path.point_from_proportion(a / (samples - 1))[:2]) for a in range(samples)])
    if not closed:
        z = np.concatenate([z, z[::-1]])
    total = len(z)
    coefs = np.fft.fft(z) / total
    freqs = np.fft.fftfreq(total, d=1 / total)
    keep = sorted(np.argsort(-np.abs(coefs))[:n_vectors], key=lambda k: (abs(freqs[k]), -freqs[k]))
    end = 1.0 if closed else 0.5
    t = ValueTracker(0)

    def chain():
        s = 0j
        pts = [s]
        for k in keep:
            s += coefs[k] * np.exp(2j * np.pi * freqs[k] * t.get_value())
            pts.append(s)
        return pts

    def p3(c):
        return np.array([c.real, c.imag, 0])

    def draw_arms(m):
        c = chain()
        m.become(VGroup(*[Line(p3(c[i]), p3(c[i + 1]), stroke_width=1.5, stroke_color=GREY_B) for i in range(len(c) - 1)]))

    def draw_circles(m):
        c = chain()
        m.become(VGroup(*[Circle(radius=abs(coefs[k]), stroke_width=1.2, stroke_color=BLUE_C, stroke_opacity=0.75)
                          .move_to(p3(c[i])) for i, k in enumerate(keep)]))

    arms = VGroup()
    arms.add_updater(draw_arms)
    circles = VGroup()
    if show_circles:
        circles.add_updater(draw_circles)
    tip = Dot(radius=0.001)
    tip.add_updater(lambda m: m.move_to(p3(chain()[-1])))
    tip.update()
    trace = TracedPath(tip.get_center, stroke_color=color, stroke_width=stroke_width)
    scene.add(circles, arms, tip, trace)
    scene.play(t.animate.set_value(end), run_time=run_time, rate_func=linear)
    for m in (circles, arms, tip):
        m.clear_updaters()
    scene.play(FadeOut(circles), FadeOut(arms), run_time=0.5)
    scene.remove(tip)
    return trace

''';

  static String? _enter(MItem i, String v) {
    final vector = i.kind == MKind.image; // images can't be drawn stroke by stroke
    final text = i.kind == MKind.text;
    return switch (i.enter) {
      MEnter.write => vector ? 'FadeIn($v)' : 'Write($v)',
      MEnter.create => i.kind == MKind.graph ? 'Create($v)' : vector ? 'FadeIn($v)' : 'Create($v)',
      MEnter.fadeIn => 'FadeIn($v)',
      MEnter.fadeInUp => 'FadeIn($v, shift=UP)',
      MEnter.fadeInDown => 'FadeIn($v, shift=DOWN)',
      MEnter.fadeInLeft => 'FadeIn($v, shift=LEFT)',
      MEnter.fadeInRight => 'FadeIn($v, shift=RIGHT)',
      MEnter.grow => 'GrowFromCenter($v)',
      MEnter.growFromEdge => 'GrowFromEdge($v, LEFT)',
      MEnter.growArrow => i.kind == MKind.arrow && i.curve.abs() < 1 ? 'GrowArrow($v)' : 'GrowFromPoint($v, ${'$v'}.get_start())',
      MEnter.spinIn => 'SpinInFromNothing($v)',
      MEnter.drawBorder => vector ? 'FadeIn($v)' : 'DrawBorderThenFill($v)',
      MEnter.letterByLetter => text ? 'AddTextLetterByLetter($v)' : 'Write($v)',
      MEnter.fourier => vector ? 'FadeIn($v)' : 'Create($v)', // a Fourier drawing plays on its own (see code())
      MEnter.traceDot => vector ? 'FadeIn($v)' : 'Create($v), MoveAlongPath(${v}_dot, $v)',
      MEnter.transform || MEnter.fadeTransform => 'FadeIn($v)', // no earlier object to morph from
      MEnter.none => null,
    };
  }

  static String? _emphasis(MItem i, String v) => switch (i.emphasis) {
        MEmphasis.indicate => 'Indicate($v)',
        MEmphasis.circumscribe => i.kind == MKind.image ? 'Indicate($v)' : 'Circumscribe($v)',
        MEmphasis.wiggle => 'Wiggle($v)',
        MEmphasis.flash => 'Flash($v, color=${_hex(i.color)})',
        MEmphasis.focusOn => 'FocusOn($v)',
        MEmphasis.wave => i.kind == MKind.image ? 'Wiggle($v)' : 'ApplyWave($v)',
        MEmphasis.passingFlash => i.kind == MKind.image ? 'Indicate($v)'
            : 'ShowPassingFlash($v.copy().set_color(YELLOW).set_stroke(width=${(i.stroke * 2).toStringAsFixed(1)}), time_width=0.4, run_time=1.2)',
        MEmphasis.none => null,
      };

  static String? _motion(MItem i, String v, String Function(double) n) => switch (i.motion) {
        MMotion.move => '$v.animate.shift([${n(i.moveBy.dx)}, ${n(i.moveBy.dy)}, 0])',
        MMotion.rotate => 'Rotate($v, angle=${n(i.rotateBy * math.pi / 180)})',
        MMotion.scale => '$v.animate.scale(${n(i.scaleBy)})',
        MMotion.color => i.kind == MKind.image ? null : '$v.animate.set_color(${_hex(i.toColor)})',
        MMotion.none => null,
      };

  static String? _exit(MItem i, String v) => switch (i.exit) {
        MExit.fadeOut => 'FadeOut($v)',
        MExit.uncreate => i.kind == MKind.image ? 'FadeOut($v)' : 'Uncreate($v)',
        MExit.shrink => 'ShrinkToCenter($v)',
        MExit.unwrite => i.kind == MKind.image ? 'FadeOut($v)' : 'Unwrite($v)',
        MExit.none => null,
      };

  static String _rate(MItem i) => i.rate == MRate.smooth ? '' : ', rate_func=${i.rate.manim}';

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
  text('Text'), math('Math'), rect('Rectangle'), circle('Circle'), triangle('Triangle'), polygon('Polygon'),
  star('Star'), arrow('Arrow'), line('Line'), dot('Dot'), brace('Brace'), graph('Graph'), numberLine('Number Line'),
  path('Drawing'), image('Image');

  final String label;
  const MKind(this.label);
}

enum MEnter {
  write('Write'), create('Create'), fadeIn('Fade In'), fadeInUp('Fade In from Below'), fadeInDown('Fade In from Above'),
  fadeInLeft('Fade In from the Right'), fadeInRight('Fade In from the Left'), grow('Grow from Centre'),
  growFromEdge('Grow from Edge'), growArrow('Grow Arrow'), spinIn('Spin In'), drawBorder('Draw Border, Then Fill'),
  fourier('Fourier Draw (epicycles)'), traceDot('Trace with a Dot'),
  letterByLetter('Letter by Letter'), transform('Transform from Previous'), fadeTransform('Fade Transform from Previous'),
  none('Appear');

  final String label;
  const MEnter(this.label);
}

enum MEmphasis {
  none('None'), indicate('Indicate'), circumscribe('Circumscribe'), wiggle('Wiggle'), flash('Flash'), focusOn('Focus On'),
  wave('Wave'), passingFlash('Passing Flash');

  final String label;
  const MEmphasis(this.label);
}

enum MMotion {
  none('None'), move('Move'), rotate('Rotate'), scale('Scale'), color('Change Colour');

  final String label;
  const MMotion(this.label);
}

enum MExit {
  none('Stays'), fadeOut('Fade Out'), uncreate('Uncreate'), shrink('Shrink Away'), unwrite('Unwrite');

  final String label;
  const MExit(this.label);
}

enum MRate {
  smooth('Smooth', 'smooth'), linear('Linear', 'linear'), thereAndBack('There and Back', 'there_and_back'),
  rushInto('Rush In', 'rush_into'), rushFrom('Rush Out', 'rush_from'), easeInOut('Ease In-Out', 'rate_functions.ease_in_out_sine'),
  bounce('Bounce', 'rate_functions.ease_out_bounce'); // the ease_* functions aren't in `from manim import *`

  final String label, manim;
  const MRate(this.label, this.manim);
}

enum MBraceDir {
  down('Below', 'DOWN'), up('Above', 'UP'), left('Left', 'LEFT'), right('Right', 'RIGHT');

  final String label, manim;
  const MBraceDir(this.label, this.manim);
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

  MGraph copyWith({double? xMin, double? xMax, double? xStep, double? yMin, double? yMax}) => MGraph(
      xMin: xMin ?? this.xMin, xMax: xMax ?? this.xMax, xStep: xStep ?? this.xStep, yMin: yMin ?? this.yMin,
      yMax: yMax ?? this.yMax, yStep: yStep);
}

/// One object on the stage. Positions and sizes are in scene units (the frame is 14.222 × 8).
class MItem {
  final int id;
  MKind kind;
  Offset pos; // centre (arrow / line: start)
  Offset end; // arrow / line end
  Size size; // shapes / graph / image / number line: width × height; dot: diameter
  String text; // text, LaTeX, the graph's formula, or a brace's label
  String font;
  double fontSize;
  Color color;
  double fill; // 0…1
  double stroke;
  double curve; // arrow / line bend, degrees (0 = straight; negative bends the other way)
  List<Offset> points; // a drawing's path, relative to pos
  bool arrowTip, closed; // a drawing ends in an arrowhead / joins back to its start
  int fourierN; // circles in a Fourier drawing
  bool showCircles;
  bool doubleHead, dashed;
  int sides; // polygon sides, star points
  MBraceDir braceDir;
  bool braceMath; // the brace's label is LaTeX
  MGraph graph;
  Uint8List? image;
  MEnter enter;
  MEmphasis emphasis;
  MMotion motion;
  Offset moveBy;
  double rotateBy, scaleBy;
  Color toColor;
  MExit exit;
  MRate rate;
  bool withPrevious; // starts together with the object before it
  bool zoom; // the camera flies to it as it enters
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
    this.curve = 0,
    this.points = const [],
    this.arrowTip = false,
    this.closed = false,
    this.fourierN = 60,
    this.showCircles = true,
    this.doubleHead = false,
    this.dashed = false,
    this.sides = 5,
    this.braceDir = MBraceDir.down,
    this.braceMath = false,
    this.graph = const MGraph(),
    this.image,
    MEnter? enter,
    this.emphasis = MEmphasis.none,
    this.motion = MMotion.none,
    this.moveBy = const Offset(2, 0),
    this.rotateBy = 90,
    this.scaleBy = 1.5,
    this.toColor = const Color(0xFFFFFF00),
    this.exit = MExit.none,
    this.rate = MRate.smooth,
    this.withPrevious = false,
    this.zoom = false,
    this.runTime = 1,
    this.wait = 0.5,
  }) : enter = enter ?? _defaultEnter(kind);

  static MEnter _defaultEnter(MKind k) => switch (k) {
        MKind.text || MKind.math => MEnter.write,
        MKind.dot => MEnter.grow,
        MKind.arrow => MEnter.growArrow,
        MKind.path => MEnter.fourier,
        MKind.image => MEnter.fadeIn,
        MKind.brace => MEnter.grow,
        _ => MEnter.create,
      };

  /// For the timeline and the comment above the object in the code: one line, no control characters
  /// (a carriage return would end a Python comment), and a formula only once it passes the check.
  String get label {
    final l = switch (kind) {
      MKind.text || MKind.math => '${kind.label}: ${text.split('\n').first}',
      MKind.graph => Formula.toPython(text) == null ? 'Graph (formula not valid)' : 'Graph: y = $text',
      MKind.brace when text.isNotEmpty => 'Brace: ${text.split('\n').first}',
      MKind.arrow when curve.abs() >= 1 => 'Curved Arrow',
      MKind.path => arrowTip ? 'Drawn Arrow' : 'Drawing',
      MKind.polygon => '$sides-sided Polygon',
      MKind.star => '$sides-point Star',
      _ => kind.label,
    };
    return l.replaceAll(RegExp(r'[\x00-\x1f\x7f\u0085  ]'), ' ');
  }

  Map<String, Object?> toJson() => {
        'id': id, 'kind': kind.name, 'pos': [pos.dx, pos.dy], 'end': [end.dx, end.dy], 'size': [size.width, size.height],
        'text': text, 'font': font, 'fontSize': fontSize, 'color': color.toARGB32(), 'fill': fill, 'stroke': stroke,
        'curve': curve, 'points': [for (final q in points) [q.dx, q.dy]], 'arrowTip': arrowTip, 'closed': closed,
        'fourierN': fourierN, 'showCircles': showCircles, 'doubleHead': doubleHead, 'dashed': dashed, 'sides': sides, 'braceDir': braceDir.name,
        'braceMath': braceMath, 'graph': graph.toJson(), if (image != null) 'image': base64Encode(image!),
        'enter': enter.name, 'emphasis': emphasis.name, 'motion': motion.name, 'moveBy': [moveBy.dx, moveBy.dy],
        'rotateBy': rotateBy, 'scaleBy': scaleBy, 'toColor': toColor.toARGB32(), 'exit': exit.name, 'rate': rate.name,
        'withPrevious': withPrevious, 'zoom': zoom, 'runTime': runTime, 'wait': wait,
      };

  static MItem? fromJson(Map<String, dynamic> j) {
    final kind = MKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null || j['id'] is! int) return null;
    Offset o(Object? v, Offset d) => v is List && v.length == 2 ? Offset((v[0] as num).toDouble(), (v[1] as num).toDouble()) : d;
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    T pick<T extends Enum>(List<T> values, String k, T def) => values.where((e) => e.name == j[k]).firstOrNull ?? def;
    final sz = j['size'];
    return MItem(
      id: j['id'] as int,
      kind: kind,
      pos: o(j['pos'], Offset.zero),
      end: o(j['end'], const Offset(2, 0)),
      size: sz is List && sz.length == 2 ? Size((sz[0] as num).toDouble(), (sz[1] as num).toDouble()) : const Size(3, 2),
      text: j['text'] as String? ?? '',
      font: j['font'] as String? ?? 'Helvetica Neue',
      fontSize: d('fontSize', 48),
      color: Color(j['color'] as int? ?? 0xFFFFFFFF),
      fill: d('fill', 0),
      stroke: d('stroke', 4),
      curve: d('curve', 0),
      points: [for (final q in (j['points'] as List? ?? const [])) if (q is List && q.length == 2) Offset((q[0] as num).toDouble(), (q[1] as num).toDouble())],
      arrowTip: j['arrowTip'] == true,
      closed: j['closed'] == true,
      fourierN: (j['fourierN'] as int? ?? 60).clamp(3, 300),
      showCircles: j['showCircles'] != false,
      doubleHead: j['doubleHead'] == true,
      dashed: j['dashed'] == true,
      sides: (j['sides'] as int? ?? 5).clamp(3, 12),
      braceDir: pick(MBraceDir.values, 'braceDir', MBraceDir.down),
      braceMath: j['braceMath'] == true,
      graph: MGraph.fromJson(j['graph'] as Map<String, dynamic>?),
      image: j['image'] is String ? base64Decode(j['image'] as String) : null,
      enter: MEnter.values.where((e) => e.name == j['enter']).firstOrNull,
      emphasis: pick(MEmphasis.values, 'emphasis', MEmphasis.none),
      motion: pick(MMotion.values, 'motion', MMotion.none),
      moveBy: o(j['moveBy'], const Offset(2, 0)),
      rotateBy: d('rotateBy', 90),
      scaleBy: d('scaleBy', 1.5),
      toColor: Color(j['toColor'] as int? ?? 0xFFFFFF00),
      exit: pick(MExit.values, 'exit', MExit.none),
      rate: pick(MRate.values, 'rate', MRate.smooth),
      withPrevious: j['withPrevious'] == true,
      zoom: j['zoom'] == true,
      runTime: d('runTime', 1),
      wait: d('wait', 0.5),
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
