import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/app_controller.dart';
import '../platform/native.dart';
import 'manim_doc.dart';
import 'manim_runner.dart';

/// Manim Studio: build a Manim video visually. Objects go on a 16:9 stage (Manim's frame), each with an
/// entrance animation, an optional emphasis and its timing; the timeline sets the order. SnapNow writes the
/// Manim code (Code shows it) and renders it with the Manim on this Mac into an MP4 in the Library.
/// Projects save themselves (~/Pictures/SnapNow/Manim Projects) as you work.
class ManimStudioPage extends StatefulWidget {
  final String? path; // a project to open; null = a new one
  const ManimStudioPage({super.key, this.path});

  /// The open studio, for the menu bar (lib/app/app_menu.dart); null when none is open.
  static final active = ValueNotifier<ManimStudioPageState?>(null);

  static Future<void> open(BuildContext context, {String? path}) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ManimStudioPage(path: path)));

  /// File › Open Manim Project…
  static Future<void> pickAndOpen(BuildContext context) async {
    final r = await FilePicker.pickFiles(
        dialogTitle: 'Open Manim Project', initialDirectory: projectsFolder, type: FileType.custom, allowedExtensions: ['snapmanim']);
    final p = r?.files.single.path;
    if (p != null && context.mounted) await open(context, path: p);
  }

  /// Tests point this at a temporary folder.
  static String? projectsFolderOverride;

  static String get projectsFolder {
    final d = Directory(projectsFolderOverride ?? '${AppController.capturesFolder}/Manim Projects');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  @override
  State<ManimStudioPage> createState() => ManimStudioPageState();
}

class ManimStudioPageState extends State<ManimStudioPage> {
  late ManimDoc doc;
  late String path;
  int? selected;
  /// The armed drawing tool: dragging on the stage draws one (a click drops one at its default size); null
  /// selects and moves objects. Draw ([MKind.path]) draws freehand.
  MKind? tool;
  double _toolCurve = 0; // the Curved arrow is the Arrow tool with a bend
  bool get drawMode => tool == MKind.path;
  static const drawable = {MKind.rect, MKind.circle, MKind.triangle, MKind.polygon, MKind.star, MKind.arrow, MKind.line};
  List<Offset>? _trail; // the path being drawn, in scene units
  int? _shapeId; // the shape being dragged out
  Offset _shapeFrom = Offset.zero;
  final _images = <int, ui.Image>{}; // decoded for the stage
  ({String path, String version})? _manim;
  bool _looked = false, _latex = true, _rendering = false, _hd = false, _showLog = false;
  final _log = StringBuffer();
  final _logScroll = ScrollController();
  String? _result;
  Timer? _saveTimer;
  final _focus = FocusNode();

  static const palette = <Color>[
    Color(0xFFFFFFFF), Color(0xFF58C4DD), Color(0xFF83C167), Color(0xFFFFFF00), Color(0xFFFC6255), Color(0xFF9A72AC),
    Color(0xFFFF862F), Color(0xFF888888), Color(0xFF000000),
  ]; // Manim's own WHITE, BLUE, GREEN, YELLOW, RED, PURPLE, ORANGE, GREY, BLACK

  @override
  void initState() {
    super.initState();
    final p = widget.path;
    if (p != null && File(p).existsSync()) {
      try {
        doc = ManimDoc.decode(File(p).readAsStringSync());
      } catch (_) {
        doc = ManimDoc();
      }
      path = p;
    } else {
      doc = ManimDoc();
      path = _newPath();
      _addStarter();
    }
    for (final i in doc.items) {
      _decodeImage(i);
    }
    _find();
    WidgetsBinding.instance.addPostFrameCallback((_) => ManimStudioPage.active.value = this);
  }

  @override
  void dispose() {
    if (ManimStudioPage.active.value == this) ManimStudioPage.active.value = null;
    _saveTimer?.cancel();
    _saveNow();
    _logScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _newPath() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    var p = '${ManimStudioPage.projectsFolder}/Manim ${d.year}-${two(d.month)}-${two(d.day)} at ${two(d.hour)}.${two(d.minute)}.${two(d.second)}.snapmanim';
    for (var n = 2; File(p).existsSync(); n++) {
      p = p.replaceFirst(RegExp(r'( \d+)?\.snapmanim$'), ' $n.snapmanim');
    }
    return p;
  }

  /// A new project starts with a title, so Render works straight away.
  void _addStarter() {
    doc.items.add(MItem(id: doc.newId(), kind: MKind.text, text: 'Hello, Manim', fontSize: 72, color: palette[1]));
  }

  Future<void> _find() async {
    final m = await ManimRunner.find();
    final tex = await ManimRunner.hasLatex();
    if (mounted) setState(() { _manim = m; _latex = tex; _looked = true; });
  }

  Future<void> _decodeImage(MItem i) async {
    final bytes = i.image;
    if (i.kind != MKind.image || bytes == null) return;
    try {
      final c = await ui.instantiateImageCodec(bytes);
      final f = await c.getNextFrame();
      if (mounted) setState(() => _images[i.id] = f.image);
    } catch (_) {}
  }

  // ---- Editing ----

  MItem? get _sel => doc.items.where((i) => i.id == selected).firstOrNull;

  /// Every change saves the project a moment later (no Save dialogs).
  void changed([VoidCallback? fn]) {
    setState(fn ?? () {});
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveNow);
  }

  void _saveNow() {
    try {
      File(path).writeAsStringSync(doc.encode());
    } catch (_) {}
  }

  /// Picks a drawing tool (again: puts it down), or adds an object that isn't drawn (text, math, graph…).
  void add(MKind kind, {double curve = 0}) async {
    if (drawable.contains(kind) || kind == MKind.path) {
      final same = tool == kind && _toolCurve == curve;
      setState(() { tool = same ? null : kind; _toolCurve = curve; selected = null; });
      return;
    }
    final n = doc.items.length;
    final at = Offset(((n % 5) - 2) * 0.6, 1.5 - (n % 4) * 1.0); // new objects don't all stack
    final id = doc.newId();
    MItem item;
    if (_make(kind, id, at, curve) case final made?) {
      item = made;
    } else {
      switch (kind) {
        case MKind.image:
          final r = await FilePicker.pickFiles(dialogTitle: 'Add Image', type: FileType.image, withData: true);
          final bytes = r?.files.single.bytes;
          if (bytes == null) return;
          item = MItem(id: id, kind: kind, pos: Offset.zero, size: const Size(6, 4), image: bytes);
          _decodeImage(item);
        default:
          return;
      }
    }
    changed(() { doc.items.add(item); selected = id; });
  }

  /// A new object of `kind` at its default size around `at` (null for images and drawings).
  MItem? _make(MKind kind, int id, Offset at, double curve) {
    MItem item;
    switch (kind) {
      case MKind.text:
        item = MItem(id: id, kind: kind, text: 'Text', pos: at, color: palette[0]);
      case MKind.math:
        item = MItem(id: id, kind: kind, text: r'a^2 + b^2 = c^2', pos: at, color: palette[0]);
      case MKind.rect:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(3, 2), color: palette[1], fill: 0.3);
      case MKind.circle:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(2, 2), color: palette[4], fill: 0.3);
      case MKind.triangle:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(2.4, 2), color: palette[2], fill: 0.3);
      case MKind.polygon:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(2.2, 2.2), color: palette[5], fill: 0.3, sides: 6);
      case MKind.star:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(2.2, 2.2), color: palette[3], fill: 0.8, sides: 5);
      case MKind.arrow || MKind.line:
        item = MItem(id: id, kind: kind, pos: at - const Offset(1.5, 0), end: at + const Offset(1.5, 0), color: palette[3], curve: curve);
      case MKind.brace:
        item = MItem(id: id, kind: kind, color: palette[0], text: 'label', fontSize: 36);
      case MKind.numberLine:
        item = MItem(id: id, kind: kind, pos: const Offset(0, -2.5), size: const Size(10, 0.6), color: palette[0],
            graph: const MGraph(xMin: -5, xMax: 5));
      case MKind.dot:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(0.16, 0.16), color: palette[3]);
      case MKind.graph:
        item = MItem(id: id, kind: kind, text: 'x^2 / 2', pos: Offset.zero, size: const Size(8, 5), color: palette[1]);
      case MKind.path || MKind.image:
        return null;
    }
    return item;
  }

  /// Dragging out the armed tool's shape: arrows and lines run from the press to the pointer, the rest fill
  /// the dragged box (polygons and stars stay regular).
  void _startShape(Offset scene) {
    final id = doc.newId();
    final item = _make(tool!, id, scene, _toolCurve)!;
    item.pos = scene;
    if (item.kind == MKind.arrow || item.kind == MKind.line) {
      item.end = scene;
    } else {
      item.size = const Size(0.01, 0.01);
    }
    setState(() { doc.items.add(item); selected = id; _shapeId = id; _shapeFrom = scene; });
  }

  void _dragShape(Offset q) {
    final i = doc.items.where((x) => x.id == _shapeId).firstOrNull;
    if (i == null) return;
    setState(() {
      if (i.kind == MKind.arrow || i.kind == MKind.line) {
        i.end = q;
        return;
      }
      var w = (q.dx - _shapeFrom.dx).abs(), h = (q.dy - _shapeFrom.dy).abs();
      if (i.kind == MKind.polygon || i.kind == MKind.star) w = h = math.max(w, h);
      i.size = Size(w, h);
      i.pos = Offset(_shapeFrom.dx + w / 2 * (q.dx < _shapeFrom.dx ? -1 : 1), _shapeFrom.dy + h / 2 * (q.dy < _shapeFrom.dy ? -1 : 1));
    });
  }

  /// A drag too short to mean a size gets the default size where it started.
  void _endShape() {
    final i = doc.items.where((x) => x.id == _shapeId).firstOrNull;
    _shapeId = null;
    if (i == null) return;
    final tiny = i.kind == MKind.arrow || i.kind == MKind.line ? (i.end - i.pos).distance < 0.2 : i.size.shortestSide < 0.15;
    if (tiny) {
      final d = _make(i.kind, i.id, _shapeFrom, _toolCurve)!;
      i..pos = d.pos..end = d.end..size = d.size;
    }
    changed();
  }

  /// A click with a tool armed drops one at its default size there.
  void _dropShape(Offset scene) {
    final id = doc.newId();
    changed(() { doc.items.add(_make(tool!, id, scene, _toolCurve)!); selected = id; });
  }

  /// A finished stroke becomes a Drawing: smoothed (each point averaged with its neighbours), thinned to the
  /// points that matter, and stored around its centre so it moves as one.
  void _finishDrawing() {
    final raw = _trail;
    _trail = null;
    if (raw == null || raw.length < 3) { setState(() {}); return; }
    const k = 2;
    final smooth = [
      for (var a = 0; a < raw.length; a++)
        if (a == 0 || a == raw.length - 1) raw[a]
        else () {
          var sum = Offset.zero, count = 0;
          for (var b = math.max(0, a - k); b <= math.min(raw.length - 1, a + k); b++) { sum += raw[b]; count++; }
          return sum / count.toDouble();
        }(),
    ];
    var eps = 0.015;
    var kept = _simplify(smooth, eps);
    while (kept.length > 120) { eps *= 1.5; kept = _simplify(smooth, eps); }
    final centre = kept.fold(Offset.zero, (a, b) => a + b) / kept.length.toDouble();
    final closed = (kept.first - kept.last).distance < 0.35 && kept.length > 6; // ended near where it began
    final id = doc.newId();
    final item = MItem(id: id, kind: MKind.path, pos: centre, points: [for (final q in kept) q - centre], closed: closed,
        arrowTip: !closed, color: palette[1], stroke: 5, runTime: 3);
    changed(() { doc.items.add(item); selected = id; });
  }

  static List<Offset> _simplify(List<Offset> pts, double eps) {
    if (pts.length < 3) return pts;
    final a = pts.first, b = pts.last, ab = b - a, len = ab.distance;
    var far = 0, best = 0.0;
    for (var i = 1; i < pts.length - 1; i++) {
      final ap = pts[i] - a;
      final d = len == 0 ? ap.distance : (ab.dx * ap.dy - ab.dy * ap.dx).abs() / len;
      if (d > best) { best = d; far = i; }
    }
    if (best <= eps) return [a, b];
    return [..._simplify(pts.sublist(0, far + 1), eps)..removeLast(), ..._simplify(pts.sublist(far), eps)];
  }

  void delete() {
    final s = _sel;
    if (s == null) return;
    changed(() { doc.items.remove(s); _images.remove(s.id); selected = null; });
  }

  void duplicate() {
    final s = _sel;
    if (s == null) return;
    final copy = MItem.fromJson({...s.toJson(), 'id': doc.newId()})!..pos += const Offset(0.4, -0.4);
    if (copy.kind == MKind.arrow || copy.kind == MKind.line) copy.end += const Offset(0.4, -0.4);
    changed(() { doc.items.insert(doc.items.indexOf(s) + 1, copy); selected = copy.id; });
    _decodeImage(copy);
  }

  // ---- Rendering ----

  void _say(String text) {
    if (!mounted) return; // a render left running after the page closed still saves to the Library
    setState(() => _log.write(text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> render() async {
    final m = _manim;
    if (m == null || _rendering || doc.items.isEmpty) return;
    if (doc.usesMath && !_latex) {
      setState(() { _showLog = true; _log..clear()..write(ManimRunner.latexHelp); });
      return;
    }
    _saveNow();
    setState(() { _rendering = true; _result = null; _log.clear(); _showLog = true; });
    final h = _hd ? 1080 : 480;
    final result = await ManimRunner.render(
      manim: m.path, code: doc.code(latex: _latex), className: ManimDoc.className, files: doc.files,
      width: (h * 16 / 9 / 2).round() * 2, height: h, fps: _hd ? 30 : 15, log: _say,
    );
    if (!mounted) return;
    setState(() { _rendering = false; _result = result; });
    if (result != null) Native.openPath(result); // plays it
  }

  void showCode() {
    final code = doc.code(latex: _latex);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Manim code'),
        content: SizedBox(
          width: 760, height: 520,
          child: SingleChildScrollView(child: SelectableText(code, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12))),
        ),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: code)), child: const Text('Copy')),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> saveAs() async {
    final p = await FilePicker.saveFile(
        dialogTitle: 'Save Manim Project', initialDirectory: ManimStudioPage.projectsFolder,
        fileName: path.split('/').last, type: FileType.custom, allowedExtensions: ['snapmanim']);
    if (p == null) return;
    setState(() => path = p.endsWith('.snapmanim') ? p : '$p.snapmanim');
    _saveNow();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): delete,
        const SingleActivator(LogicalKeyboardKey.backspace): delete,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true): duplicate,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): render,
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() { selected = null; tool = null; }),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: scheme.surface,
          appBar: _bar(scheme),
          body: Column(children: [
            if (_looked && _manim == null) _banner(scheme, ManimRunner.installHelp),
            if (_looked && _manim != null && doc.usesMath && !_latex) _banner(scheme, ManimRunner.latexHelp),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: Column(children: [Expanded(child: _stage(scheme)), _timeline(scheme)])),
                _properties(scheme),
              ]),
            ),
            if (_showLog) _logPanel(scheme),
          ]),
        ),
      ),
    );
  }

  PreferredSizeWidget _bar(ColorScheme scheme) {
    BoxDecoration? armed(bool on) => on ? BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(8)) : null;
    Widget toolButton(MKind k, IconData icon) => Tooltip(
          message: drawable.contains(k) ? '${k.label}: drag on the stage to draw it; Esc to stop' : 'Add ${k.label}',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => add(k),
            child: Container(
              decoration: armed(tool == k && _toolCurve == 0),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 20),
                Text(k.label, style: const TextStyle(fontSize: 10.5)),
              ]),
            ),
          ),
        );
    return AppBar(
      backgroundColor: scheme.surfaceContainerLow,
      toolbarHeight: 58,
      titleSpacing: 0,
      title: Row(children: [
        toolButton(MKind.text, Icons.title),
        toolButton(MKind.math, Icons.functions),
        _menuTool('Shapes', Icons.category_outlined, armed, [
          (MKind.rect, 'Rectangle'), (MKind.circle, 'Circle'), (MKind.triangle, 'Triangle'), (MKind.polygon, 'Polygon'),
          (MKind.star, 'Star'), (MKind.dot, 'Dot'),
        ]),
        toolButton(MKind.arrow, Icons.arrow_right_alt),
        Tooltip(
          message: 'Curved Arrow: drag on the stage to draw it; Esc to stop',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => add(MKind.arrow, curve: 60),
            child: Container(
              decoration: armed(tool == MKind.arrow && _toolCurve != 0),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: const Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.redo, size: 20), Text('Curved', style: TextStyle(fontSize: 10.5))]),
            ),
          ),
        ),
        Tooltip(
          message: 'Draw: drag on the stage to draw a path (an arrow, a shape, anything); Esc to stop',
          child: InkWell(
            key: const ValueKey('studio-draw'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => add(MKind.path),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: drawMode ? scheme.primaryContainer : null, borderRadius: BorderRadius.circular(8)),
              child: const Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.gesture, size: 20), Text('Draw', style: TextStyle(fontSize: 10.5))]),
            ),
          ),
        ),
        toolButton(MKind.line, Icons.horizontal_rule),
        toolButton(MKind.brace, Icons.data_array),
        toolButton(MKind.graph, Icons.show_chart),
        toolButton(MKind.numberLine, Icons.linear_scale),
        toolButton(MKind.image, Icons.image_outlined),
      ]),
      actions: [
        TextButton.icon(onPressed: showCode, icon: const Icon(Icons.code, size: 18), label: const Text('Code')),
        const SizedBox(width: 8),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('Preview')), ButtonSegment(value: true, label: Text('HD 1080p'))],
          selected: {_hd},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _hd = v.first),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          key: const ValueKey('studio-render'),
          onPressed: _manim == null || _rendering || doc.items.isEmpty ? null : render,
          icon: _rendering
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow, size: 18),
          label: Text(_rendering ? 'Rendering…' : 'Render'),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  /// A toolbar button with a menu of kinds (the shapes).
  Widget _menuTool(String label, IconData icon, BoxDecoration? Function(bool) armed, List<(MKind, String)> kinds) =>
      PopupMenuButton<MKind>(
        tooltip: 'Pick a shape, then drag on the stage to draw it',
        onSelected: add,
        itemBuilder: (_) => [
          for (final (k, l) in kinds) CheckedPopupMenuItem(value: k, height: 32, checked: tool == k, child: Text(l)),
        ],
        child: Container(
          decoration: armed(kinds.any((k) => k.$1 == tool)),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(kinds.where((k) => k.$1 == tool).isEmpty ? icon : Icons.edit_outlined, size: 20),
            Text(kinds.where((k) => k.$1 == tool).map((k) => k.$2).firstOrNull ?? '$label ▾', style: const TextStyle(fontSize: 10.5)),
          ]),
        ),
      );

  Widget _banner(ColorScheme scheme, String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(text, style: TextStyle(fontFamily: 'Menlo', fontSize: 12, color: scheme.onErrorContainer)),
      );

  // The stage: scene units ↔ pixels
  late Size _stageSize;
  Offset _toPx(Offset s) => Offset((s.dx / ManimDoc.frameW + 0.5) * _stageSize.width, (0.5 - s.dy / ManimDoc.frameH) * _stageSize.height);
  Offset _toScene(Offset p) => Offset((p.dx / _stageSize.width - 0.5) * ManimDoc.frameW, (0.5 - p.dy / _stageSize.height) * ManimDoc.frameH);
  double get _ppu => _stageSize.height / ManimDoc.frameH; // pixels per scene unit

  // Dragging: which object, and which part (body, end point, or the size corner)
  int? _dragId;
  String _dragPart = 'body';
  Offset _dragLast = Offset.zero;

  Widget _stage(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: LayoutBuilder(builder: (context, c) {
            _stageSize = c.biggest;
            return MouseRegion(
              cursor: tool != null ? SystemMouseCursors.precise : MouseCursor.defer,
              child: GestureDetector(
              key: const ValueKey('studio-stage'),
              onTapDown: (d) { if (tool == null) setState(() => selected = _hit(d.localPosition)?.$1); },
              onTapUp: (d) { if (tool != null && !drawMode) _dropShape(_toScene(d.localPosition)); },
              onPanStart: (d) {
                if (drawMode) { setState(() => _trail = [_toScene(d.localPosition)]); return; }
                if (tool != null) return _startShape(_toScene(d.localPosition));
                final h = _hit(d.localPosition);
                if (h == null) return;
                setState(() { selected = h.$1; _dragId = h.$1; _dragPart = h.$2; _dragLast = d.localPosition; });
              },
              onPanUpdate: (d) {
                if (_trail != null) {
                  final q = _toScene(d.localPosition);
                  if ((q - _trail!.last).distance * _ppu >= 2) setState(() => _trail!.add(q));
                  return;
                }
                if (_shapeId != null) return _dragShape(_toScene(d.localPosition));
                final i = doc.items.where((x) => x.id == _dragId).firstOrNull;
                if (i == null) return;
                final delta = (d.localPosition - _dragLast) / _ppu;
                final ds = Offset(delta.dx, -delta.dy); // scene y points up
                _dragLast = d.localPosition;
                setState(() {
                  switch (_dragPart) {
                    case 'end':
                      i.end += ds;
                    case 'start':
                      i.pos += ds;
                    case 'size':
                      final w = math.max(0.2, i.size.width + ds.dx * 2), h = math.max(0.2, i.size.height - ds.dy * 2);
                      final square = i.kind == MKind.image || i.kind == MKind.polygon || i.kind == MKind.star;
                      i.size = square ? Size(w, w) : i.kind == MKind.numberLine ? Size(w, i.size.height) : Size(w, h);
                    default:
                      i.pos += ds;
                      if (i.kind == MKind.arrow || i.kind == MKind.line) i.end += ds;
                  }
                });
              },
              onPanEnd: (_) {
                if (_trail != null) return _finishDrawing();
                if (_shapeId != null) return _endShape();
                _dragId = null;
                changed();
              },
              child: ClipRect(
                child: CustomPaint(
                  size: c.biggest,
                  painter: _StagePainter(doc: doc, selected: selected, images: _images, toPx: _toPx, bounds: _bounds, ppu: _ppu,
                      trail: _trail),
                ),
              ),
            ));
          }),
        ),
      ),
    );
  }

  /// The object (and part) under a stage point: the selected object's handles first, then front to back.
  (int, String)? _hit(Offset p) {
    final s = _sel;
    if (s != null) {
      for (final (part, at) in _handles(s)) {
        if ((at - p).distance < 10) return (s.id, part);
      }
    }
    for (final i in doc.items.reversed) {
      if (_bounds(i).inflate(6).contains(p)) {
        if (i.kind == MKind.arrow || i.kind == MKind.line || i.kind == MKind.path) {
          final pts = (i.kind == MKind.path ? _StagePainter.pathPoints(i) : _StagePainter.curvePoints(i)).map(_toPx).toList();
          var near = false;
          for (var k = 1; k < pts.length && !near; k++) {
            near = _distToSegment(p, pts[k - 1], pts[k]) <= 10;
          }
          if (!near) continue;
        }
        return (i.id, 'body');
      }
    }
    return null;
  }

  List<(String, Offset)> _handles(MItem i) => switch (i.kind) {
        MKind.arrow || MKind.line => [('start', _toPx(i.pos)), ('end', _toPx(i.end))],
        MKind.rect || MKind.circle || MKind.triangle || MKind.polygon || MKind.star || MKind.graph || MKind.image ||
        MKind.numberLine => [('size', _bounds(i).bottomRight)],
        _ => const [],
      };

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a, len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  /// An object's box on the stage, in pixels.
  Rect _bounds(MItem i) {
    final c = _toPx(i.pos);
    switch (i.kind) {
      case MKind.text || MKind.math:
        final tp = _StagePainter.textFor(i, _ppu);
        return Rect.fromCenter(center: c, width: tp.width, height: tp.height);
      case MKind.arrow || MKind.line:
        final pts = _StagePainter.curvePoints(i).map(_toPx).toList();
        return pts.fold(Rect.fromPoints(pts.first, pts.first), (r, q) => r.expandToInclude(Rect.fromPoints(q, q)));
      case MKind.polygon || MKind.star:
        return Rect.fromCenter(center: c, width: i.size.width * _ppu, height: i.size.width * _ppu);
      case MKind.path:
        final pts = _StagePainter.pathPoints(i).map(_toPx).toList();
        if (pts.isEmpty) return Rect.fromCenter(center: c, width: 10, height: 10);
        return pts.fold(Rect.fromPoints(pts.first, pts.first), (r, q) => r.expandToInclude(Rect.fromPoints(q, q)));
      case MKind.brace:
        return _StagePainter.braceRect(doc, i, _bounds, _ppu) ?? Rect.fromCenter(center: c, width: 60, height: 20);
      case MKind.image:
        final img = _images[i.id];
        final w = i.size.width * _ppu, h = img == null ? w * 0.66 : w * img.height / img.width;
        return Rect.fromCenter(center: c, width: w, height: h);
      default:
        return Rect.fromCenter(center: c, width: i.size.width * _ppu, height: i.size.height * _ppu);
    }
  }

  Widget _timeline(ColorScheme scheme) {
    return Container(
      height: 64,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: doc.items.isEmpty
          ? Center(child: Text('Add objects with the buttons above; they appear in this order.', style: TextStyle(color: scheme.onSurfaceVariant)))
          : ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: doc.items.length,
              onReorder: (from, to) => changed(() {
                final it = doc.items.removeAt(from);
                doc.items.insert(to > from ? to - 1 : to, it);
              }),
              itemBuilder: (context, n) {
                final i = doc.items[n];
                final on = i.id == selected;
                return ReorderableDragStartListener(
                  key: ValueKey(i.id),
                  index: n,
                  child: GestureDetector(
                    onTap: () => setState(() => selected = i.id),
                    child: Container(
                      width: 170,
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: on ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: on ? scheme.primary : scheme.outlineVariant),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('${n + 1}. ${i.label}', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        Text('${i.enter.label} · ${i.runTime.toStringAsFixed(1)} s', maxLines: 1,
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _properties(ColorScheme scheme) {
    final i = _sel;
    final kids = <Widget>[];
    Widget head(String t) => Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: scheme.onSurfaceVariant)),
        );
    Widget slider(String label, double v, double min, double max, ValueChanged<double> on, {int digits = 1}) => Row(children: [
          SizedBox(width: 74, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(child: Slider(value: v.clamp(min, max), min: min, max: max, onChanged: (x) => setState(() => on(x)), onChangeEnd: (_) => changed())),
          SizedBox(width: 36, child: Text(v.toStringAsFixed(digits), style: const TextStyle(fontSize: 11.5))),
        ]);
    Widget check(String label, bool v, ValueChanged<bool> on) => CheckboxListTile(
          dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, visualDensity: VisualDensity.compact,
          value: v, title: Text(label, style: const TextStyle(fontSize: 12.5)), onChanged: (x) => changed(() => on(x ?? false)),
        );
    Widget dropdown<T>(String label, T value, List<T> values, String Function(T) name, ValueChanged<T> on) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DropdownButtonFormField<T>(
            key: ValueKey('$label-$selected'),
            value: value,
            isDense: true,
            decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
            items: [for (final x in values) DropdownMenuItem(value: x, child: Text(name(x), style: const TextStyle(fontSize: 13)))],
            onChanged: (x) { if (x != null) changed(() => on(x)); },
          ),
        );
    Widget colors(Color current, ValueChanged<Color> on) => Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in palette)
            GestureDetector(
              onTap: () => changed(() => on(c)),
              child: Container(
                width: 22, height: 22,
                decoration: BoxDecoration(
                  color: c, shape: BoxShape.circle,
                  border: Border.all(color: c.toARGB32() == current.toARGB32() ? scheme.primary : scheme.outlineVariant,
                      width: c.toARGB32() == current.toARGB32() ? 2.5 : 1),
                ),
              ),
            ),
        ]);
    Widget field(String hint, String value, ValueChanged<String> on, {int lines = 1, String? error, Key? key}) => TextFormField(
          key: key ?? ValueKey('f-$selected-$hint'),
          initialValue: value,
          maxLines: lines,
          minLines: 1,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(isDense: true, labelText: hint, errorText: error, border: const OutlineInputBorder()),
          onChanged: (v) => changed(() => on(v)),
        );

    if (i == null) {
      kids.addAll([
        head('Video'),
        Text('Background', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        colors(doc.background, (c) => doc.background = c),
        const SizedBox(height: 8),
        CheckboxListTile(
          dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
          value: doc.fadeOutAtEnd, title: const Text('Fade everything out at the end', style: TextStyle(fontSize: 12.5)),
          onChanged: (v) => changed(() => doc.fadeOutAtEnd = v ?? true),
        ),
        slider('End hold', doc.endHold, 0, 6, (v) => doc.endHold = v),
        const SizedBox(height: 12),
        Text('Click an object to edit it. Drag to move; drag the dots to resize or move an arrow\'s ends. '
            'Delete removes it, ⌘D duplicates, ⌘↩ renders.', style: TextStyle(fontSize: 12, height: 1.4, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        Text('Project saves itself:\n${path.split('/').last}', style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        TextButton(onPressed: saveAs, child: const Text('Save As…')),
      ]);
    } else {
      kids.add(head(i.kind.label));
      switch (i.kind) {
        case MKind.text:
          kids.addAll([field('Text', i.text, (v) => i.text = v, lines: 4), const SizedBox(height: 8),
            slider('Size', i.fontSize, 12, 160, (v) => i.fontSize = v, digits: 0)]);
        case MKind.math:
          kids.addAll([field('LaTeX', i.text, (v) => i.text = v, lines: 3), const SizedBox(height: 4),
            Text(r'e.g. \frac{1}{2}, x^2, \int_0^1 f(x)\,dx, \sum_{n=1}^\infty', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8), slider('Size', i.fontSize, 12, 160, (v) => i.fontSize = v, digits: 0)]);
        case MKind.rect || MKind.circle || MKind.triangle:
          kids.addAll([slider('Width', i.size.width, 0.2, 14, (v) => i.size = Size(v, i.size.height)),
            slider('Height', i.size.height, 0.2, 8, (v) => i.size = Size(i.size.width, v)),
            slider('Fill', i.fill, 0, 1, (v) => i.fill = v), slider('Line', i.stroke, 0, 16, (v) => i.stroke = v)]);
        case MKind.polygon || MKind.star:
          kids.addAll([
            slider(i.kind == MKind.star ? 'Points' : 'Sides', i.sides.toDouble(), i.kind == MKind.star ? 4 : 3, 12,
                (v) => i.sides = v.round(), digits: 0),
            slider('Size', i.size.width, 0.3, 8, (v) => i.size = Size(v, v)),
            slider('Fill', i.fill, 0, 1, (v) => i.fill = v), slider('Line', i.stroke, 0, 16, (v) => i.stroke = v)]);
        case MKind.arrow || MKind.line:
          kids.addAll([
            slider('Curve', i.curve, -180, 180, (v) => i.curve = v.abs() < 4 ? 0 : v, digits: 0),
            slider('Line', i.stroke, 1, 16, (v) => i.stroke = v),
            if (i.kind == MKind.arrow) check('Arrowhead at both ends', i.doubleHead, (v) => i.doubleHead = v),
            if (i.kind == MKind.line) check('Dashed', i.dashed, (v) => i.dashed = v),
          ]);
        case MKind.brace:
          final t = doc.braceTarget(doc.items.indexOf(i));
          kids.addAll([
            Text(t == null ? 'Add the object to brace first (the brace wraps the one before it in the timeline).'
                : 'Wraps: ${doc.items[t].label}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            DropdownButtonFormField<MBraceDir>(
              key: ValueKey('brace-$selected'),
              value: i.braceDir,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Side', isDense: true, border: OutlineInputBorder()),
              items: [for (final d in MBraceDir.values) DropdownMenuItem(value: d, child: Text(d.label, style: const TextStyle(fontSize: 13)))],
              onChanged: (d) => changed(() => i.braceDir = d ?? i.braceDir),
            ),
            const SizedBox(height: 8),
            field('Label (optional)', i.text, (v) => i.text = v),
            check('Label is LaTeX', i.braceMath, (v) => i.braceMath = v),
            slider('Label size', i.fontSize, 12, 96, (v) => i.fontSize = v, digits: 0),
          ]);
        case MKind.path:
          kids.addAll([
            slider('Line', i.stroke, 1, 16, (v) => i.stroke = v),
            check('Closed (joins back to the start)', i.closed, (v) => i.closed = v),
            if (!i.closed) check('Arrowhead at the end', i.arrowTip, (v) => i.arrowTip = v),
            Text('Tip: set "Enters with" to Fourier Draw for spinning circles that trace it.',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ]);
        case MKind.numberLine:
          kids.addAll([
            Row(children: [
              Expanded(child: field('from', '${i.graph.xMin}', (v) => i.graph = i.graph.copyWith(xMin: double.tryParse(v)))),
              const SizedBox(width: 6),
              Expanded(child: field('to', '${i.graph.xMax}', (v) => i.graph = i.graph.copyWith(xMax: double.tryParse(v)))),
              const SizedBox(width: 6),
              Expanded(child: field('step', '${i.graph.xStep}', (v) {
                final st = double.tryParse(v);
                if (st != null && st > 0) i.graph = i.graph.copyWith(xStep: st);
              })),
            ]),
            slider('Length', i.size.width, 2, 14, (v) => i.size = Size(v, i.size.height)),
          ]);
        case MKind.dot:
          kids.add(slider('Size', i.size.width, 0.05, 1, (v) => i.size = Size(v, v), digits: 2));
        case MKind.graph:
          final ok = Formula.toPython(i.text) != null;
          kids.addAll([
            field('y =', i.text, (v) => i.text = v, error: ok ? null : 'Use x, numbers, + - * / ^ ( ) and sin, cos, sqrt…'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: field('x from', '${i.graph.xMin}', (v) => i.graph = i.graph.copyWith(xMin: double.tryParse(v)))),
              const SizedBox(width: 6),
              Expanded(child: field('x to', '${i.graph.xMax}', (v) => i.graph = i.graph.copyWith(xMax: double.tryParse(v)))),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: field('y from', '${i.graph.yMin}', (v) => i.graph = i.graph.copyWith(yMin: double.tryParse(v)))),
              const SizedBox(width: 6),
              Expanded(child: field('y to', '${i.graph.yMax}', (v) => i.graph = i.graph.copyWith(yMax: double.tryParse(v)))),
            ]),
            slider('Width', i.size.width, 2, 14, (v) => i.size = Size(v, i.size.height)),
            slider('Height', i.size.height, 1.5, 8, (v) => i.size = Size(i.size.width, v)),
            slider('Line', i.stroke, 1, 12, (v) => i.stroke = v),
          ]);
        case MKind.image:
          kids.add(slider('Width', i.size.width, 0.5, 14, (v) => i.size = Size(v, v)));
      }
      if (i.kind != MKind.image) {
        kids.addAll([head('Colour'), colors(i.color, (c) => i.color = c)]);
      }
      final index = doc.items.indexOf(i);
      final transformOk = doc.transformSource(index) != null;
      final transforms = {MEnter.transform, MEnter.fadeTransform};
      final enter = (transforms.contains(i.enter) && !transformOk) || (i.enter == MEnter.fourier && i.kind != MKind.path)
          ? MEnter.fadeIn : i.enter;
      kids.addAll([
        head('Animation'),
        dropdown('Enters with', enter, [
          for (final e in MEnter.values)
            if ((!transforms.contains(e) || transformOk) && (e != MEnter.fourier || i.kind == MKind.path) &&
                (e != MEnter.traceDot || i.kind != MKind.image)) e,
        ], (e) => e.label, (e) => i.enter = e),
        if (i.enter == MEnter.fourier && i.kind == MKind.path) ...[
          slider('Circles', i.fourierN.toDouble(), 3, 150, (v) => i.fourierN = v.round(), digits: 0),
          check('Show the circles', i.showCircles, (v) => i.showCircles = v),
        ],
        if (index > 0) check('Start together with the previous one', i.withPrevious, (v) => i.withPrevious = v),
        dropdown('Easing', i.rate, MRate.values, (r) => r.label, (r) => i.rate = r),
        slider('Run time', i.runTime, 0.2, 5, (v) => i.runTime = v),
        check('Zoom the camera to it', i.zoom, (v) => i.zoom = v),
        const SizedBox(height: 6),
        dropdown('Then', i.emphasis, MEmphasis.values, (e) => e.label, (e) => i.emphasis = e),
        dropdown('Afterwards', i.motion, MMotion.values, (m) => m.label, (m) => i.motion = m),
        if (i.motion == MMotion.move)
          Row(children: [
            Expanded(child: field('move x', '${i.moveBy.dx}', (v) => i.moveBy = Offset(double.tryParse(v) ?? i.moveBy.dx, i.moveBy.dy))),
            const SizedBox(width: 6),
            Expanded(child: field('move y', '${i.moveBy.dy}', (v) => i.moveBy = Offset(i.moveBy.dx, double.tryParse(v) ?? i.moveBy.dy))),
          ]),
        if (i.motion == MMotion.rotate) slider('Degrees', i.rotateBy, -360, 360, (v) => i.rotateBy = v, digits: 0),
        if (i.motion == MMotion.scale) slider('Scale by', i.scaleBy, 0.2, 4, (v) => i.scaleBy = v),
        if (i.motion == MMotion.color) colors(i.toColor, (c) => i.toColor = c),
        if (i.motion != MMotion.none) const SizedBox(height: 8),
        slider('Pause after', i.wait, 0, 5, (v) => i.wait = v),
        dropdown('Then leaves', i.exit, MExit.values, (e) => e.label, (e) => i.exit = e),
        const SizedBox(height: 8),
        Row(children: [
          TextButton.icon(onPressed: duplicate, icon: const Icon(Icons.copy, size: 16), label: const Text('Duplicate')),
          TextButton.icon(onPressed: delete, icon: const Icon(Icons.delete_outline, size: 16), label: const Text('Delete')),
        ]),
      ]);
    }
    return Container(
      width: 300,
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, border: Border(left: BorderSide(color: scheme.outlineVariant))),
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: kids),
    );
  }

  Widget _logPanel(ColorScheme scheme) => Container(
        height: 150,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(8)),
        child: Stack(children: [
          SingleChildScrollView(
            controller: _logScroll,
            child: SizedBox(
              width: double.infinity,
              child: SelectableText(_log.toString(), style: const TextStyle(fontFamily: 'Menlo', fontSize: 11.5, color: Color(0xFFD4D4D4))),
            ),
          ),
          Positioned(
            right: 0, top: 0,
            child: Row(children: [
              if (_result != null) ...[
                TextButton(onPressed: () => Native.openPath(_result!), child: const Text('Play')),
                TextButton(onPressed: () => Native.reveal(_result!), child: const Text('Show in Finder')),
              ],
              IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.white70), onPressed: () => setState(() => _showLog = false)),
            ]),
          ),
        ]),
      );
}

/// Draws the stage as Manim will show it (close enough to place things; Render shows the real thing).
class _StagePainter extends CustomPainter {
  final ManimDoc doc;
  final int? selected;
  final Map<int, ui.Image> images;
  final Offset Function(Offset) toPx;
  final Rect Function(MItem) bounds; // the stage's own (a brace wraps another object's box)
  final double ppu;
  final List<Offset>? trail; // the stroke being drawn (scene units)
  _StagePainter({required this.doc, required this.selected, required this.images, required this.toPx, required this.bounds,
      required this.ppu, this.trail});

  /// A drawing's points on the stage, in scene units (closed ones end where they began).
  static List<Offset> pathPoints(MItem i) => [for (final q in i.points) i.pos + q, if (i.closed && i.points.isNotEmpty) i.pos + i.points.first];

  /// An arrow's or line's path in scene units: straight, or the arc Manim draws for `curve` degrees
  /// (ArcBetweenPoints: positive angles turn counter-clockwise from the start).
  static List<Offset> curvePoints(MItem i) {
    final a = i.pos, b = i.end;
    final th = i.curve * math.pi / 180;
    if (th.abs() < 0.02 || (b - a).distance < 1e-6) return [a, b];
    final chord = b - a, len = chord.distance, mid = (a + b) / 2;
    final perp = Offset(-chord.dy, chord.dx) / len; // left of the chord (y up)
    final centre = mid + perp * (len / 2 / math.tan(th / 2));
    final a0 = math.atan2(a.dy - centre.dy, a.dx - centre.dx), r = (a - centre).distance;
    return [for (var k = 0; k <= 48; k++) centre + Offset(math.cos(a0 + th * k / 48), math.sin(a0 + th * k / 48)) * r];
  }

  /// Where a brace sits on the stage (pixels): along the chosen side of the object it wraps.
  static Rect? braceRect(ManimDoc doc, MItem i, Rect Function(MItem) bounds, double ppu) {
    final t = doc.braceTarget(doc.items.indexOf(i));
    if (t == null) return null;
    final r = bounds(doc.items[t]);
    final d = 0.3 * ppu, gap = 0.1 * ppu;
    return switch (i.braceDir) {
      MBraceDir.down => Rect.fromLTWH(r.left, r.bottom + gap, r.width, d),
      MBraceDir.up => Rect.fromLTWH(r.left, r.top - gap - d, r.width, d),
      MBraceDir.left => Rect.fromLTWH(r.left - gap - d, r.top, d, r.height),
      MBraceDir.right => Rect.fromLTWH(r.right + gap, r.top, d, r.height),
    };
  }

  static Path _polygon(Offset c, double radius, int n, {bool star = false}) {
    final pts = <Offset>[];
    final count = star ? n * 2 : n;
    for (var k = 0; k < count; k++) {
      final ang = -math.pi / 2 + k * 2 * math.pi / count;
      final rr = star && k.isOdd ? radius * 0.42 : radius;
      pts.add(c + Offset(math.cos(ang), math.sin(ang)) * rr);
    }
    return Path()..addPolygon(pts, true);
  }

  void _head(Canvas canvas, Offset tip, Offset from, Color color) {
    if ((tip - from).distance < 0.5) return;
    final u = (tip - from) / (tip - from).distance, n = Offset(-u.dy, u.dx), h = 0.25 * ppu;
    canvas.drawPath(Path()..addPolygon([tip, tip - u * h + n * h * 0.5, tip - u * h - n * h * 0.5], true), Paint()..color = color);
  }

  /// Manim's font_size 48 is about 0.5 units of cap height; a font's em is ~1.45 times that.
  static TextPainter textFor(MItem i, double ppu) {
    final math = i.kind == MKind.math;
    return TextPainter(
      text: TextSpan(
        text: i.text.isEmpty ? ' ' : i.text,
        style: TextStyle(
          color: i.color,
          fontSize: i.fontSize / 48 * 0.5 * 1.45 * ppu,
          fontFamily: math ? 'Times New Roman' : (i.font == 'Helvetica Neue' ? null : i.font),
          fontStyle: math ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = doc.background);
    for (final i in doc.items) {
      final stroke = Paint()
        ..color = i.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, i.stroke * 0.01 * ppu)
        ..strokeCap = StrokeCap.round;
      final fill = Paint()..color = i.color.withValues(alpha: i.fill);
      final c = toPx(i.pos);
      switch (i.kind) {
        case MKind.text || MKind.math:
          final tp = textFor(i, ppu);
          tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
        case MKind.rect:
          final r = Rect.fromCenter(center: c, width: i.size.width * ppu, height: i.size.height * ppu);
          canvas..drawRect(r, fill)..drawRect(r, stroke);
        case MKind.circle:
          final r = Rect.fromCenter(center: c, width: i.size.width * ppu, height: i.size.height * ppu);
          canvas..drawOval(r, fill)..drawOval(r, stroke);
        case MKind.triangle:
          final r = Rect.fromCenter(center: c, width: i.size.width * ppu, height: i.size.height * ppu);
          final tri = Path()..addPolygon([r.topCenter, r.bottomRight, r.bottomLeft], true);
          canvas..drawPath(tri, fill)..drawPath(tri, stroke);
        case MKind.polygon || MKind.star:
          final path = _polygon(c, i.size.width / 2 * ppu, i.sides, star: i.kind == MKind.star);
          canvas..drawPath(path, fill)..drawPath(path, stroke);
        case MKind.arrow || MKind.line:
          final pts = curvePoints(i).map(toPx).toList();
          final path = Path()..addPolygon(pts, false);
          if (i.dashed && i.kind == MKind.line) {
            for (final m in path.computeMetrics()) {
              for (var d = 0.0; d < m.length; d += 14) {
                canvas.drawPath(m.extractPath(d, math.min(d + 8, m.length)), stroke);
              }
            }
          } else {
            canvas.drawPath(path, stroke);
          }
          if (i.kind == MKind.arrow) {
            _head(canvas, pts.last, pts[pts.length - 2], i.color);
            if (i.doubleHead) _head(canvas, pts.first, pts[1], i.color);
          }
        case MKind.brace:
          final r = braceRect(doc, i, bounds, ppu);
          if (r == null) break;
          final horizontal = i.braceDir == MBraceDir.down || i.braceDir == MBraceDir.up;
          final out = i.braceDir == MBraceDir.down || i.braceDir == MBraceDir.right ? 1.0 : -1.0;
          final b = Path();
          if (horizontal) {
            final y0 = out > 0 ? r.top : r.bottom, y1 = out > 0 ? r.bottom : r.top;
            b..moveTo(r.left, y0)..quadraticBezierTo(r.left, (y0 + y1) / 2, r.left + r.width * 0.1, (y0 + y1) / 2)
              ..lineTo(r.center.dx - r.width * 0.05, (y0 + y1) / 2)..lineTo(r.center.dx, y1)
              ..lineTo(r.center.dx + r.width * 0.05, (y0 + y1) / 2)..lineTo(r.right - r.width * 0.1, (y0 + y1) / 2)
              ..quadraticBezierTo(r.right, (y0 + y1) / 2, r.right, y0);
          } else {
            final x0 = out > 0 ? r.left : r.right, x1 = out > 0 ? r.right : r.left;
            b..moveTo(x0, r.top)..quadraticBezierTo((x0 + x1) / 2, r.top, (x0 + x1) / 2, r.top + r.height * 0.1)
              ..lineTo((x0 + x1) / 2, r.center.dy - r.height * 0.05)..lineTo(x1, r.center.dy)
              ..lineTo((x0 + x1) / 2, r.center.dy + r.height * 0.05)..lineTo((x0 + x1) / 2, r.bottom - r.height * 0.1)
              ..quadraticBezierTo((x0 + x1) / 2, r.bottom, x0, r.bottom);
          }
          canvas.drawPath(b, Paint()..color = i.color..style = PaintingStyle.stroke..strokeWidth = 2);
          if (i.text.isNotEmpty) {
            final tp = textFor(i, ppu);
            final at = switch (i.braceDir) {
              MBraceDir.down => Offset(r.center.dx - tp.width / 2, r.bottom + 4),
              MBraceDir.up => Offset(r.center.dx - tp.width / 2, r.top - tp.height - 4),
              MBraceDir.left => Offset(r.left - tp.width - 6, r.center.dy - tp.height / 2),
              MBraceDir.right => Offset(r.right + 6, r.center.dy - tp.height / 2),
            };
            tp.paint(canvas, at);
          }
        case MKind.path:
          final pts = pathPoints(i).map(toPx).toList();
          if (pts.length < 2) break;
          final path = Path()..moveTo(pts.first.dx, pts.first.dy);
          for (var k = 1; k < pts.length - 1; k++) {
            final mid = (pts[k] + pts[k + 1]) / 2; // midpoint quadratic smoothing, like Manim's smooth points
            path.quadraticBezierTo(pts[k].dx, pts[k].dy, mid.dx, mid.dy);
          }
          path.lineTo(pts.last.dx, pts.last.dy);
          canvas.drawPath(path, stroke..strokeJoin = StrokeJoin.round);
          if (i.arrowTip && !i.closed) _head(canvas, pts.last, pts[pts.length - 2], i.color);
        case MKind.numberLine:
          final g = i.graph;
          final w = i.size.width * ppu;
          final a = c - Offset(w / 2, 0), b = c + Offset(w / 2, 0);
          canvas.drawLine(a, b, Paint()..color = i.color..strokeWidth = 2);
          if (g.xMax > g.xMin && g.xStep > 0 && (g.xMax - g.xMin) / g.xStep <= 60) {
            for (var x = g.xMin; x <= g.xMax + 1e-9; x += g.xStep) {
              final px = a.dx + (x - g.xMin) / (g.xMax - g.xMin) * w;
              canvas.drawLine(Offset(px, c.dy - 5), Offset(px, c.dy + 5), Paint()..color = i.color..strokeWidth = 1.5);
              final tp = TextPainter(
                  text: TextSpan(text: x == x.roundToDouble() ? '${x.round()}' : x.toStringAsFixed(1),
                      style: TextStyle(color: i.color, fontSize: 0.28 * ppu)),
                  textDirection: TextDirection.ltr)..layout();
              tp.paint(canvas, Offset(px - tp.width / 2, c.dy + 8));
            }
          }
        case MKind.dot:
          canvas.drawCircle(c, i.size.width / 2 * ppu, Paint()..color = i.color);
        case MKind.graph:
          _graph(canvas, i, c);
        case MKind.image:
          final img = images[i.id];
          if (img == null) break;
          final w = i.size.width * ppu, h = w * img.height / img.width;
          canvas.drawImageRect(img, Offset.zero & Size(img.width.toDouble(), img.height.toDouble()),
              Rect.fromCenter(center: c, width: w, height: h), Paint()..filterQuality = FilterQuality.medium);
      }
      if (i.id == selected) _selection(canvas, i, c);
    }
    final t = trail;
    if (t != null && t.length > 1) {
      canvas.drawPath(Path()..addPolygon(t.map(toPx).toList(), false), Paint()
        ..color = const Color(0xFF58C4DD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
    }
  }

  void _graph(Canvas canvas, MItem i, Offset c) {
    final g = i.graph;
    final box = Rect.fromCenter(center: c, width: i.size.width * ppu, height: i.size.height * ppu);
    if (g.xMax <= g.xMin || g.yMax <= g.yMin) return;
    Offset at(double x, double y) =>
        Offset(box.left + (x - g.xMin) / (g.xMax - g.xMin) * box.width, box.bottom - (y - g.yMin) / (g.yMax - g.yMin) * box.height);
    final axes = Paint()..color = const Color(0xFFBBBBBB)..strokeWidth = 1.5;
    final y0 = (0.0).clamp(g.yMin, g.yMax), x0 = (0.0).clamp(g.xMin, g.xMax);
    canvas.drawLine(at(g.xMin, y0), at(g.xMax, y0), axes);
    canvas.drawLine(at(x0, g.yMin), at(x0, g.yMax), axes);
    final path = Path();
    var pen = false;
    for (var k = 0; k <= 200; k++) {
      final x = g.xMin + (g.xMax - g.xMin) * k / 200;
      final y = Formula.eval(i.text, x);
      if (y == null || y < g.yMin - 1 || y > g.yMax + 1) { pen = false; continue; }
      final p = at(x, y.clamp(g.yMin, g.yMax));
      pen ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      pen = true;
    }
    canvas.save();
    canvas.clipRect(box);
    canvas.drawPath(path, Paint()..color = i.color..style = PaintingStyle.stroke..strokeWidth = math.max(1.5, i.stroke * 0.01 * ppu));
    canvas.restore();
  }

  void _selection(Canvas canvas, MItem i, Offset c) {
    final accent = Paint()..color = const Color(0xFF2F7CF6)..style = PaintingStyle.stroke..strokeWidth = 1.5;
    final dot = Paint()..color = const Color(0xFF2F7CF6);
    switch (i.kind) {
      case MKind.arrow || MKind.line:
        canvas..drawCircle(c, 5, dot)..drawCircle(toPx(i.end), 5, dot);
      case MKind.text || MKind.math:
        final tp = textFor(i, ppu);
        canvas.drawRect(Rect.fromCenter(center: c, width: tp.width + 8, height: tp.height + 4), accent);
      case MKind.brace:
        final r = braceRect(doc, i, bounds, ppu);
        if (r != null) canvas.drawRect(r.inflate(4), accent);
      case MKind.path:
        canvas.drawRect(bounds(i).inflate(6), accent);
      case MKind.polygon || MKind.star:
        final r = Rect.fromCenter(center: c, width: i.size.width * ppu, height: i.size.width * ppu);
        canvas..drawRect(r.inflate(3), accent)..drawCircle(r.bottomRight, 5, dot);
      default:
        final img = images[i.id];
        final w = i.size.width * ppu;
        final h = i.kind == MKind.image ? (img == null ? w * 0.66 : w * img.height / img.width) : i.size.height * ppu;
        final r = Rect.fromCenter(center: c, width: w, height: h);
        canvas..drawRect(r.inflate(3), accent)..drawCircle(r.bottomRight, 5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
