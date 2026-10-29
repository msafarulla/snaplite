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
  final _images = <int, ui.Image>{}; // decoded for the stage
  ({String path, String version})? _manim;
  bool _looked = false, _latex = true, _rendering = false, _hd = false, _showLog = false;
  final _log = StringBuffer();
  final _logScroll = ScrollController();
  String? _result;
  Process? _process;
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
    _process?.kill();
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

  void add(MKind kind) async {
    final id = doc.newId();
    final n = doc.items.length;
    final at = Offset(((n % 5) - 2) * 0.6, 1.5 - (n % 4) * 1.0); // new objects don't all stack
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
      case MKind.arrow || MKind.line:
        item = MItem(id: id, kind: kind, pos: at - const Offset(1.5, 0), end: at + const Offset(1.5, 0), color: palette[3]);
      case MKind.dot:
        item = MItem(id: id, kind: kind, pos: at, size: const Size(0.16, 0.16), color: palette[3]);
      case MKind.graph:
        item = MItem(id: id, kind: kind, text: 'x^2 / 2', pos: Offset.zero, size: const Size(8, 5), color: palette[1]);
      case MKind.image:
        final r = await FilePicker.pickFiles(dialogTitle: 'Add Image', type: FileType.image, withData: true);
        final bytes = r?.files.single.bytes;
        if (bytes == null) return;
        item = MItem(id: id, kind: kind, pos: Offset.zero, size: const Size(6, 4), image: bytes);
        _decodeImage(item);
    }
    changed(() { doc.items.add(item); selected = id; });
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
      width: (h * 16 / 9 / 2).round() * 2, height: h, fps: _hd ? 30 : 15, log: _say, started: (p) => _process = p,
    );
    _process = null;
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
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => selected = null),
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
    Widget tool(MKind k, IconData icon) => Tooltip(
          message: 'Add ${k.label}',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => add(k),
            child: Padding(
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
        tool(MKind.text, Icons.title),
        tool(MKind.math, Icons.functions),
        tool(MKind.rect, Icons.crop_square),
        tool(MKind.circle, Icons.circle_outlined),
        tool(MKind.arrow, Icons.arrow_right_alt),
        tool(MKind.line, Icons.horizontal_rule),
        tool(MKind.dot, Icons.fiber_manual_record),
        tool(MKind.graph, Icons.show_chart),
        tool(MKind.image, Icons.image_outlined),
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
            return GestureDetector(
              key: const ValueKey('studio-stage'),
              onTapDown: (d) => setState(() => selected = _hit(d.localPosition)?.$1),
              onPanStart: (d) {
                final h = _hit(d.localPosition);
                if (h == null) return;
                setState(() { selected = h.$1; _dragId = h.$1; _dragPart = h.$2; _dragLast = d.localPosition; });
              },
              onPanUpdate: (d) {
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
                      i.size = i.kind == MKind.image ? Size(w, w) : Size(w, h);
                    default:
                      i.pos += ds;
                      if (i.kind == MKind.arrow || i.kind == MKind.line) i.end += ds;
                  }
                });
              },
              onPanEnd: (_) { _dragId = null; changed(); },
              child: ClipRect(
                child: CustomPaint(
                  size: c.biggest,
                  painter: _StagePainter(doc: doc, selected: selected, images: _images, toPx: _toPx, ppu: _ppu),
                ),
              ),
            );
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
        if (i.kind == MKind.arrow || i.kind == MKind.line) {
          final a = _toPx(i.pos), b = _toPx(i.end);
          if (_distToSegment(p, a, b) > 10) continue;
        }
        return (i.id, 'body');
      }
    }
    return null;
  }

  List<(String, Offset)> _handles(MItem i) => switch (i.kind) {
        MKind.arrow || MKind.line => [('start', _toPx(i.pos)), ('end', _toPx(i.end))],
        MKind.rect || MKind.circle || MKind.graph || MKind.image => [('size', _bounds(i).bottomRight)],
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
        return Rect.fromPoints(c, _toPx(i.end));
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
        case MKind.rect || MKind.circle:
          kids.addAll([slider('Width', i.size.width, 0.2, 14, (v) => i.size = Size(v, i.size.height)),
            slider('Height', i.size.height, 0.2, 8, (v) => i.size = Size(i.size.width, v)),
            slider('Fill', i.fill, 0, 1, (v) => i.fill = v), slider('Line', i.stroke, 0, 16, (v) => i.stroke = v)]);
        case MKind.arrow || MKind.line:
          kids.add(slider('Line', i.stroke, 1, 16, (v) => i.stroke = v));
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
      final transformOk = (i.kind == MKind.text || i.kind == MKind.math) && doc.transformSource(doc.items.indexOf(i)) != null;
      kids.addAll([
        head('Animation'),
        DropdownButtonFormField<MEnter>(
          key: ValueKey('enter-$selected'),
          value: i.enter == MEnter.transform && !transformOk ? MEnter.write : i.enter,
          isDense: true,
          decoration: const InputDecoration(labelText: 'Enters with', isDense: true, border: OutlineInputBorder()),
          items: [
            for (final e in MEnter.values)
              if (e != MEnter.transform || transformOk) DropdownMenuItem(value: e, child: Text(e.label, style: const TextStyle(fontSize: 13))),
          ],
          onChanged: (e) => changed(() => i.enter = e ?? i.enter),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<MEmphasis>(
          key: ValueKey('emphasis-$selected'),
          value: i.emphasis,
          isDense: true,
          decoration: const InputDecoration(labelText: 'Then', isDense: true, border: OutlineInputBorder()),
          items: [for (final e in MEmphasis.values) DropdownMenuItem(value: e, child: Text(e.label, style: const TextStyle(fontSize: 13)))],
          onChanged: (e) => changed(() => i.emphasis = e ?? i.emphasis),
        ),
        const SizedBox(height: 4),
        slider('Run time', i.runTime, 0.2, 5, (v) => i.runTime = v),
        slider('Pause after', i.wait, 0, 5, (v) => i.wait = v),
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
  final double ppu;
  _StagePainter({required this.doc, required this.selected, required this.images, required this.toPx, required this.ppu});

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
        case MKind.arrow || MKind.line:
          final a = c, b = toPx(i.end);
          canvas.drawLine(a, b, stroke);
          if (i.kind == MKind.arrow && (b - a).distance > 1) {
            final u = (b - a) / (b - a).distance, n = Offset(-u.dy, u.dx), head = 0.25 * ppu;
            canvas.drawPath(Path()..moveTo(b.dx, b.dy)..lineTo((b - u * head + n * head * 0.5).dx, (b - u * head + n * head * 0.5).dy)
              ..lineTo((b - u * head - n * head * 0.5).dx, (b - u * head - n * head * 0.5).dy)..close(), Paint()..color = i.color);
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
