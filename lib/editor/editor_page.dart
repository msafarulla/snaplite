import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:window_manager/window_manager.dart';
import '../app/app_controller.dart';
import '../model/annotation.dart';
import '../platform/native.dart';
import 'canvas_painter.dart';
import 'properties_panel.dart';
import 'quick_styles.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});
  @override
  State<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends State<EditorPage> implements PanelHost {
  CanvasState? _state;
  String? _path; // file on disk this canvas came from; Save writes back to it
  final _undo = <CanvasState>[];
  final _redo = <CanvasState>[];
  int _nextId = 1;

  Tool _tool = Tool.arrow;
  Color _color = const Color(0xFFE8332A);
  StrokeSize _size = StrokeSize.medium;
  int? _selection;
  final _canvasKey = GlobalKey();
  final _focus = FocusNode(debugLabel: "editor"); // keyboard shortcuts go to the editor, not the hidden Library grid

  void focus() => _focus.requestFocus();

  // Active gesture
  Offset? _createStart;
  Offset? _createCurrent;
  List<Offset>? _penPoints;
  int? _dragId;
  int? _resizeHandle; // null => move
  Offset _lastPoint = Offset.zero;
  CanvasState? _gestureSnapshot;

  static const _palette = [
    Color(0xFFE8332A), Color(0xFF56B947), Color(0xFF3B8EEA), Color(0xFFF5D33A),
    Color(0xFFFF7A00), Color(0xFF8E44EF), Color(0xFF1E1E1E), Color(0xFFFFFFFF),
  ];

  /// Remembered style per kind, shared with the Swift app (UserDefaults "style.arrow|line|shape").
  final _styleDefaults = <StyleKind, ArrowStyle>{};

  /// Toolbar tools from Settings › Toolbar (Swift raw values), in the Swift app's toolbar order.
  static const _swiftTool = [Tool.select, Tool.arrow, Tool.line, Tool.box, Tool.ellipse, Tool.pen, Tool.highlight,
    Tool.text, Tool.callout, Tool.step, Tool.blur, Tool.spotlight, Tool.crop, Tool.grabText];
  static const _toolOrder = [Tool.select, Tool.arrow, Tool.text, Tool.callout, Tool.box, Tool.ellipse, Tool.line,
    Tool.pen, Tool.step, Tool.highlight, Tool.blur, Tool.spotlight, Tool.crop];
  static const _defaultTools = {Tool.select, Tool.arrow, Tool.text, Tool.callout, Tool.box, Tool.step, Tool.highlight,
    Tool.blur, Tool.crop};
  Set<Tool> _visibleTools = _defaultTools;

  @override
  void initState() {
    super.initState();
    _makeBlankCanvas(1200, 800);
    _loadPrefs();
    Native.onColorPicked = (rgb) => pickColor(Color(0xFF000000 | rgb), refresh: false);
  }

  Future<void> _loadPrefs() async {
    for (final k in StyleKind.values) {
      final raw = await Native.getDataString('style.${k.name}');
      if (raw == null) continue;
      try {
        final s = ArrowStyle.fromJson(jsonDecode(raw));
        if (s != null) _styleDefaults[k] = s;
      } catch (_) {}
    }
    final raw = await Native.toolbarTools();
    if (raw != null) {
      _visibleTools = {for (final i in raw) if (i >= 0 && i < _swiftTool.length) _swiftTool[i]};
    }
    await QuickStyles.load();
    if (mounted) setState(() {});
  }

  ArrowStyle _styleFor(StyleKind k) => _styleDefaults[k] ?? k.builtIn;

  double get _density => _state?.density ?? 1;

  Future<void> _makeBlankCanvas(int w, int h) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    final img = await recorder.endRecording().toImage(w, h);
    setState(() => _state = _savedState = CanvasState(image: img));
  }

  void _commit(CanvasState next, {bool snapshot = true}) {
    if (snapshot && _state != null) {
      _undo.add(_state!);
      _redo.clear();
    }
    _clearCopied(); // any edit ends the "copied" marching ants
    setState(() => _state = next);
  }

  CanvasState? _savedState; // the state last opened or saved

  /// Edits since the file was opened or last saved.
  bool get hasUnsavedChanges => _state != null && !identical(_state, _savedState);
  String? get path => _path;

  void _undoAction() {
    if (_undo.isEmpty || _state == null) return;
    _redo.add(_state!);
    setState(() { _state = _undo.removeLast(); _selection = null; });
  }

  void _redoAction() {
    if (_redo.isEmpty || _state == null) return;
    _undo.add(_state!);
    setState(() { _state = _redo.removeLast(); _selection = null; });
  }

  Annotation? _annotation(int? id) => _state?.annotations.where((a) => a.id == id).firstOrNull;

  // ---- Image selection and copy feedback (as in the Swift app) ----

  /// The whole image is selected (Select tool click on empty canvas, or ⌘A): dashed border + square handles.
  bool _imageSelected = false;
  /// After Copy, "marching ants" run around the image until the next edit or click.
  bool _copied = false;
  final _ants = ValueNotifier<double>(0);
  Timer? _antsTimer;
  /// Resizing the canvas by its square handles: handle index, new rect (image coords), grab offset.
  (int, Rect, Offset)? _canvasDrag;
  double _viewScale = 1; // view points per image point, from the last layout

  bool get _showsCanvasHandles => (_imageSelected || _copied) && _selection == null;

  Rect get _imageRect => Rect.fromLTWH(0, 0, _state!.image.width.toDouble(), _state!.image.height.toDouble());

  /// Square handles just outside the image border (image coords).
  List<Offset> get _canvasHandles => CanvasPainter.rectHandles(_imageRect.inflate(4 / _viewScale));

  void selectImage() => setState(() { _selection = null; _imageSelected = true; });

  void _showCopied() {
    _antsTimer?.cancel();
    _antsTimer = Timer.periodic(const Duration(milliseconds: 83), (_) => _ants.value = (_ants.value + 1) % 8);
    setState(() => _copied = true);
  }

  void _clearCopied() {
    if (!_copied) return;
    _antsTimer?.cancel();
    _antsTimer = null;
    setState(() => _copied = false);
  }

  @override
  void dispose() {
    _antsTimer?.cancel();
    super.dispose();
  }

  // ---- Hit testing (the Swift app's rules) ----

  /// Topmost annotation a click can grab with the current tool. Area shapes (highlight, blur, spotlight)
  /// count from inside only for Select or their own tool; boxes and ellipses only by their outline, so you
  /// can still draw inside them.
  Annotation? _hit(Offset p) {
    final t = 6 / _viewScale;
    for (final a in (_state?.annotations ?? const <Annotation>[]).reversed) {
      final interior = switch (a.shape) {
        BlurShape() => _tool == Tool.select || _tool == Tool.blur,
        HighlightShape() => _tool == Tool.select || _tool == Tool.highlight,
        SpotlightShape() => _tool == Tool.select || _tool == Tool.spotlight,
        _ => true,
      };
      if (_hitTest(a, p, t, interior: interior)) return a;
    }
    return null;
  }

  bool _hitTest(Annotation a, Offset p, double t, {bool interior = true}) {
    final reach = t + a.lineWidth;
    bool nearEdge(Rect r, double reach) => r.inflate(reach).contains(p) && !r.deflate(reach).contains(p);
    switch (a.shape) {
      case ArrowShape(:final from, :final to, :final bend) || LineShape(:final from, :final to, :final bend):
        return _nearCurve(from, to, bend, p, reach);
      case PenShape(:final points):
        for (var i = 0; i < points.length - 1; i++) {
          if (_distToSeg(p, points[i], points[i + 1]) <= reach) return true;
        }
        return false;
      case RectShape(:final rect):
        return nearEdge(rect, reach);
      case EllipseShape(:final rect):
        final rx = math.max(rect.width / 2, 1.0), ry = math.max(rect.height / 2, 1.0);
        final d = math.sqrt(math.pow((p.dx - rect.center.dx) / rx, 2) + math.pow((p.dy - rect.center.dy) / ry, 2));
        return (d - 1).abs() * math.min(rx, ry) <= reach;
      case HighlightShape(:final rect) || SpotlightShape(:final rect) || BlurShape(:final rect):
        return interior ? rect.inflate(t).contains(p) : nearEdge(rect, t + 2);
      default:
        return _bounds(a)?.inflate(t).contains(p) ?? false;
    }
  }

  /// Bounds of text, callouts, steps and images (for hit testing and their selection box).
  Rect? _bounds(Annotation a) => switch (a.shape) {
        TextShape(:final string, :final at) => () {
            final tp = TextPainter(text: TextSpan(text: string, style: TextStyle(fontSize: a.fontSize, fontWeight: FontWeight.w700)),
                textDirection: TextDirection.ltr)..layout();
            return Rect.fromLTWH(at.dx, at.dy, tp.width, tp.height);
          }(),
        CalloutShape(:final string, :final at) => CanvasPainter.calloutRect(string, at, a.fontSize),
        StepShape(:final center) => Rect.fromCircle(center: center, radius: a.stepDiameter / 2),
        _ => a.rect,
      };

  bool _nearCurve(Offset from, Offset to, Offset bend, Offset p, double reach) {
    final mid = Offset((from.dx + to.dx) / 2 + bend.dx, (from.dy + to.dy) / 2 + bend.dy);
    final ctrl = Offset(2 * mid.dx - (from.dx + to.dx) / 2, 2 * mid.dy - (from.dy + to.dy) / 2);
    Offset prev = from;
    for (var i = 1; i <= 24; i++) {
      final tt = i / 24;
      final q = _quad(from, ctrl, to, tt);
      if (_distToSeg(p, prev, q) <= reach) return true;
      prev = q;
    }
    return false;
  }

  Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return Offset(u * u * a.dx + 2 * u * t * c.dx + t * t * b.dx, u * u * a.dy + 2 * u * t * c.dy + t * t * b.dy);
  }

  double _distToSeg(Offset p, Offset a, Offset b) {
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final l2 = dx * dx + dy * dy;
    if (l2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / l2;
    t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * dx, a.dy + t * dy)).distance;
  }

  List<Offset> _handlesOf(Annotation a) => CanvasPainter.handlesOf(a);

  // ---- Gesture handling ----

  /// New annotations stay inside the image (as in the Swift app).
  Offset _clamp(Offset p) {
    final s = _state;
    if (s == null) return p;
    return Offset(p.dx.clamp(0.0, s.image.width.toDouble()), p.dy.clamp(0.0, s.image.height.toDouble()));
  }

  void _beginMove(Annotation a, Offset p) {
    _dragId = a.id; _resizeHandle = null; _lastPoint = p; _gestureSnapshot = _state;
  }

  /// `p` is in image coordinates and may lie outside the image (the canvas area around it).
  void _down(Offset p) {
    final handleTolerance = 9 / _viewScale;
    final canvasHandle = _showsCanvasHandles
        ? _canvasHandles.indexWhere((h) => (h - p).distance <= 8 / _viewScale) : -1;
    _clearCopied();

    if (canvasHandle >= 0) {
      final edge = CanvasPainter.rectHandles(_imageRect)[canvasHandle];
      setState(() => _canvasDrag = (canvasHandle, _imageRect, edge - p));
      return;
    }
    final selected = _annotation(_selection);
    if (selected != null) {
      final handles = _handlesOf(selected);
      for (var i = 0; i < handles.length; i++) {
        if ((handles[i] - p).distance <= handleTolerance) {
          _dragId = selected.id; _resizeHandle = i; _lastPoint = p; _gestureSnapshot = _state;
          return;
        }
      }
      if (_hitTest(selected, p, 6 / _viewScale)) {
        _beginMove(selected, p);
        return;
      }
    }
    // Any tool: clicking an existing annotation selects it for editing (drag moves it)
    final hit = _hit(p);
    if (hit != null) {
      setState(() { _selection = hit.id; _imageSelected = false; });
      _beginMove(hit, p);
      return;
    }
    setState(() => _selection = null);
    if (_tool == Tool.select) {
      setState(() => _imageSelected = _imageRect.contains(p)); // empty canvas selects the image
      return;
    }
    setState(() => _imageSelected = false);
    if (!_imageRect.inflate(24 / _viewScale).contains(p)) return; // far outside the image: nothing to draw
    if (_tool == Tool.text) { _addText(_clamp(p)); return; }
    if (_tool == Tool.step) { _addStep(_clamp(p)); return; }
    if (_tool == Tool.pen) { _penPoints = [_clamp(p)]; return; }
    _createStart = _clamp(p); _createCurrent = _createStart;
  }

  void _move(Offset p) {
    if (_canvasDrag case (final h, _, final grab)) {
      final r = _resizedRect(_imageRect, h, p + grab);
      final n = Rect.fromLTRB(math.min(r.left, r.right), math.min(r.top, r.bottom),
          math.max(r.left, r.right), math.max(r.top, r.bottom));
      if (n.width >= 16 && n.height >= 16) setState(() => _canvasDrag = (h, n, grab));
    } else if (_dragId != null) {
      final a = _annotation(_dragId);
      if (a == null) return;
      final next = _resizeHandle == null ? a.movedBy(p - _lastPoint) : _resized(a, _resizeHandle!, p);
      _lastPoint = p;
      _replace(next, snapshot: false);
    } else if (_penPoints != null) {
      if ((_penPoints!.last - _clamp(p)).distance >= 1) setState(() => _penPoints!.add(_clamp(p)));
    } else if (_createStart != null) {
      setState(() => _createCurrent = _clamp(p));
    }
  }

  void _up(Offset p) {
    if (_canvasDrag case (_, final rect, _)) {
      setState(() => _canvasDrag = null);
      if (rect != _imageRect) _resizeCanvasTo(rect);
      return;
    }
    if (_dragId != null) {
      final wasImage = _annotation(_dragId)?.shape is ImageShape;
      // One undo step for the whole move/resize, and none for a plain click
      if (_gestureSnapshot != null && !identical(_gestureSnapshot, _state)) { _undo.add(_gestureSnapshot!); _redo.clear(); }
      _dragId = null; _resizeHandle = null; _gestureSnapshot = null;
      if (wasImage) _growAfterEdit();
      return;
    }
    if (_penPoints != null) {
      final pts = _penPoints!; _penPoints = null;
      if (pts.length > 1) {
        _add(Annotation(id: _nextId++, scale: _density, shape: PenShape(pts), color: _color, size: _size, arrowStyle: _styleFor(StyleKind.shape)));
      }
      return;
    }
    if (_createStart != null) {
      final a = _createStart!, b = _createCurrent ?? p;
      _createStart = null; _createCurrent = null;
      _finishCreate(a, b);
    }
  }

  /// New canvas = `rect` of the current image (image coords): added space shows the canvas colour, or it crops.
  Future<void> _resizeCanvasTo(Rect rect) async {
    final s = _state!;
    final w = rect.width.round(), h = rect.height.round();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(s.image, -rect.topLeft, Paint());
    final out = await rec.endRecording().toImage(w, h);
    _commit(s.copyWith(image: out, annotations: [for (final a in s.annotations) a.movedBy(-rect.topLeft)]));
    setState(() => _imageSelected = true);
  }

  void _finishCreate(Offset a, Offset b) {
    if (_tool == Tool.callout) {
      // Drag from what to point at to where the bubble goes; a click points at the click
      final dragged = (b - a).distance * _viewScale > 12;
      _promptText().then((text) {
        if (text != null && text.isNotEmpty) _addCallout(text, a, dragged ? b : null);
      });
      return;
    }
    final rect = Rect.fromPoints(a, b);
    final big = rect.width > 3 && rect.height > 3;
    Shape? shape;
    switch (_tool) {
      case Tool.arrow:
        if ((b - a).distance > 4) shape = ArrowShape(a, b);
      case Tool.line:
        if ((b - a).distance > 4) shape = LineShape(a, b);
      case Tool.box:
        if (big) shape = RectShape(rect);
      case Tool.ellipse:
        if (big) shape = EllipseShape(rect);
      case Tool.highlight:
        if (big) shape = HighlightShape(rect);
      case Tool.spotlight:
        if (big) shape = SpotlightShape(rect);
      case Tool.blur:
        if (big) shape = BlurShape(rect, null);
      case Tool.crop:
        if (rect.width > 8 && rect.height > 8) _crop(rect);
      default:
        break;
    }
    if (shape != null) {
      final kind = StyleKind.ofTool(_tool);
      _add(Annotation(id: _nextId++, scale: _density, shape: shape, color: _color, size: _size,
          arrowStyle: kind == null ? ArrowStyle.arrow : _styleFor(kind)));
    }
  }

  void _add(Annotation a) {
    final next = _state!.copyWith(annotations: [..._state!.annotations, a]);
    _commit(next);
    setState(() => _selection = a.id);
  }

  void _replace(Annotation a, {bool snapshot = true}) {
    final anns = [for (final x in _state!.annotations) x.id == a.id ? a : x];
    _commit(_state!.copyWith(annotations: anns), snapshot: snapshot);
  }

  Annotation _resized(Annotation a, int handle, Offset p) {
    switch (a.shape) {
      case CalloutShape(:final string, :final at):
        return a.copyWith(shape: CalloutShape(string, at, tail: _clamp(p)));
      case ArrowShape(:final from, :final to, :final bend):
        if (handle == 2) return a.copyWith(shape: ArrowShape(from, to, bend: Offset(p.dx - (from.dx + to.dx) / 2, p.dy - (from.dy + to.dy) / 2)));
        return a.copyWith(shape: ArrowShape(handle == 0 ? p : from, handle == 1 ? p : to, bend: bend));
      case LineShape(:final from, :final to, :final bend):
        if (handle == 2) return a.copyWith(shape: LineShape(from, to, bend: Offset(p.dx - (from.dx + to.dx) / 2, p.dy - (from.dy + to.dy) / 2)));
        return a.copyWith(shape: LineShape(handle == 0 ? p : from, handle == 1 ? p : to, bend: bend));
      default:
        final r = a.rect;
        if (r == null) return a;
        return a.withRect(_resizedRect(r, handle, p));
    }
  }

  Rect _resizedRect(Rect r, int i, Offset p) {
    switch (i) {
      case 0: return Rect.fromPoints(r.bottomRight, p);
      case 1: return Rect.fromPoints(r.bottomLeft, p);
      case 2: return Rect.fromPoints(r.topRight, p);
      case 3: return Rect.fromPoints(r.topLeft, p);
      case 4: return Rect.fromLTRB(r.left, p.dy, r.right, r.bottom);
      case 5: return Rect.fromLTRB(r.left, r.top, r.right, p.dy);
      case 6: return Rect.fromLTRB(p.dx, r.top, r.right, r.bottom);
      case 7: return Rect.fromLTRB(r.left, r.top, p.dx, r.bottom);
      default: return r;
    }
  }

  Future<void> _addText(Offset p) async {
    final text = await _promptText();
    if (text == null || text.isEmpty) return;
    _add(Annotation(id: _nextId++, scale: _density, shape: TextShape(text, p), color: _color, size: _size));
  }

  /// A callout whose pointer tip is at `tip`. Dragged: the bubble is centred where the drag ended (`boxCenter`).
  /// A plain click (`boxCenter` null): the bubble sits up and to the right of the click (below it near the top).
  void _addCallout(String text, Offset tip, Offset? boxCenter) {
    final fs = _size.fontSize * _density;
    final r = CanvasPainter.calloutRect(text, Offset.zero, fs);
    Offset at;
    if (boxCenter != null) {
      at = boxCenter - r.center;
    } else {
      at = tip + Offset(fs * 1.2, -(r.height + fs * 1.6)) - r.topLeft;
      if (at.dy + r.top < 0) at = tip + Offset(fs * 1.2, fs * 1.6) - r.topLeft;
    }
    // Keep the whole bubble on the image
    final s = _state;
    if (s != null) {
      final box = r.shift(at);
      final dx = box.left < 0 ? -box.left : (box.right > s.image.width ? s.image.width - box.right : 0.0);
      final dy = box.top < 0 ? -box.top : (box.bottom > s.image.height ? s.image.height - box.bottom : 0.0);
      at += Offset(dx, dy);
    }
    _add(Annotation(id: _nextId++, scale: _density, shape: CalloutShape(text, at, tail: tip), color: _color, size: _size));
  }

  void _addStep(Offset p) {
    _add(Annotation(id: _nextId++, scale: _density, shape: StepShape(p), color: _color, size: _size));
  }

  Future<String?> _promptText() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Text'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Enter text'),
            onSubmitted: (v) => Navigator.pop(ctx, v)), // Return adds it
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Add')),
        ],
      ),
    );
  }

  Future<void> _growAfterEdit() async {
    if (_state == null) return;
    final grown = await _grownToFit(_state!);
    if (!identical(grown, _state)) _commit(grown);
  }

  /// Loads an image file (a capture, or one picked by the user) as a fresh canvas.
  Future<void> openFile(String path) async {
    final bytes = await File(path).readAsBytes(); // read fully first: the file may be rewritten later
    if (bytes.isEmpty) return;
    final frame = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
    // Retina captures record 144 dpi; images without DPI info count as Retina when they are large
    final density = await Native.imageDensity(path) ?? (frame.image.width > 1800 ? 2.0 : 1.0);
    setState(() {
      _undo.clear(); _redo.clear(); _selection = null;
      _state = CanvasState(image: frame.image, density: density);
      _path = path;
      _savedState = _state;
      _imageSelected = false;
      _canvasDrag = null;
    });
    _clearCopied();
    await windowManager.setTitle('SnapLite — ${path.split('/').last}');
  }

  Future<void> openImageDialog() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result?.files.firstOrNull?.path;
    if (path != null) await AppController.instance.openEditor(path); // via the Library: offers to save first
  }

  Future<Uint8List?> _flatPng() async {
    if (_state == null) return null;
    final data = await (await _flatten()).toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  /// Copies the flattened image (no toast, as in the Swift app).
  /// Copies the flattened image; marching ants run around it instead of a toast (as in the Swift app).
  Future<void> _copyImage() async {
    final png = await _flatPng();
    if (png == null) return;
    await Pasteboard.writeImage(png);
    setState(() => _selection = null);
    _showCopied();
  }

  /// Saves back to the capture's file, or a new file in Pictures › SnapLite.
  Future<void> save() async {
    final png = await _flatPng();
    if (png == null) return;
    final path = _path ?? AppController.newCapturePath();
    await File(path).writeAsBytes(png, flush: true);
    _path = path;
    setState(() => _savedState = _state);
    await windowManager.setTitle('SnapLite — ${path.split('/').last}');
    AppController.instance.capturesVersion.value++;
    await Native.toast('Saved');
  }

  /// OCR of the whole image: clipboard plus a toast showing what was read.
  Future<void> _copyAllText() async {
    final png = await _flatPng();
    if (png == null) return;
    final tmp = '${Directory.systemTemp.path}/snaplite-ocr-${DateTime.now().millisecondsSinceEpoch}.png';
    await File(tmp).writeAsBytes(png, flush: true);
    await Native.toast('Reading text…', symbol: 'text.viewfinder');
    final text = await Native.ocr(tmp);
    try { File(tmp).deleteSync(); } catch (_) {}
    await Native.copyText(text);
  }

  Future<void> _addOverlay() async {
    if (_state == null) return;
    final result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null) return;
    await addOverlayBytes(bytes);
  }

  /// Drops an image into the canvas as a movable, resizable overlay, centred on `globalPosition`
  /// (a filmstrip drop) or on the canvas; the canvas grows if the overlay spills past it.
  Future<void> addOverlayFile(String path, {Offset? globalPosition}) async =>
      addOverlayBytes(await File(path).readAsBytes(), globalPosition: globalPosition);

  Future<void> addOverlayBytes(Uint8List bytes, {Offset? globalPosition}) async {
    if (_state == null) return;
    final codec = await ui.instantiateImageCodec(bytes);
    final overlay = (await codec.getNextFrame()).image;
    final cw = _state!.image.width.toDouble(), ch = _state!.image.height.toDouble();
    final nw = overlay.width.toDouble(), nh = overlay.height.toDouble();
    final fit = math.min(math.min(cw * 0.6 / nw, ch * 0.6 / nh), 1.0);
    final w = nw * fit, h = nh * fit;
    var center = Offset(cw / 2, ch / 2);
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (globalPosition != null && box != null && box.hasSize) {
      center = box.globalToLocal(globalPosition) * (cw / box.size.width);
    }
    final rect = Rect.fromCenter(center: center, width: w, height: h);
    final ann = Annotation(id: _nextId++, scale: _density, shape: ImageShape(rect, overlay), color: const Color(0x00000000));
    var next = _state!.copyWith(annotations: [..._state!.annotations, ann]);
    next = await _grownToFit(next);
    _commit(next);
    setState(() { _selection = ann.id; _tool = Tool.select; });
  }

  /// Grows the base canvas to fit every image overlay, shifting content if it spills past top/left.
  Future<CanvasState> _grownToFit(CanvasState s) async {
    var union = Rect.fromLTWH(0, 0, s.image.width.toDouble(), s.image.height.toDouble());
    final base = union;
    for (final a in s.annotations) {
      if (a.shape is ImageShape) {
        final r = a.rect;
        if (r != null) union = union.expandToInclude(r);
      }
    }
    if (union == base) return s;
    final newW = union.width.round(), newH = union.height.round();
    final shift = Offset(-union.left, -union.top);
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    c.drawImage(s.image, shift, Paint());
    final newImage = await recorder.endRecording().toImage(newW, newH);
    return s.copyWith(image: newImage, annotations: [for (final a in s.annotations) a.movedBy(shift)]);
  }

  Future<ui.Image> _flatten() async {
    final s = _state!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    CanvasPainter(state: s, selectionId: null, scale: 1)
        .paint(canvas, Size(s.image.width.toDouble(), s.image.height.toDouble()));
    return recorder.endRecording().toImage(s.image.width, s.image.height);
  }

  Future<void> _exportPng() async {
    if (_state == null) return;
    final flat = await _flatten();
    final data = await flat.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final bytes = data.buffer.asUint8List();
    await FileSaver.instance.saveFile(name: 'snaplite', bytes: bytes, fileExtension: 'png', mimeType: MimeType.png);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Exported PNG')));
  }

  // ---- Canvas operations (flatten / flip / trim / crop / resize / color) ----

  Future<ui.Image> _cropImage(ui.Image src, Rect rect) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImageRect(src, rect, Rect.fromLTWH(0, 0, rect.width, rect.height), Paint());
    return rec.endRecording().toImage(rect.width.round(), rect.height.round());
  }

  Future<void> _crop(Rect rect) async {
    if (_state == null) return;
    final cropped = await _cropImage(_state!.image, rect);
    final shift = Offset(-rect.left, -rect.top);
    _commit(_state!.copyWith(image: cropped, annotations: [for (final a in _state!.annotations) a.movedBy(shift)]));
    setState(() { _selection = null; _tool = Tool.select; });
  }

  Future<void> _flattenInPlace() async {
    if (_state == null || _state!.annotations.isEmpty) return;
    final flat = await _flatten();
    _commit(_state!.copyWith(annotations: const [], image: flat));
    setState(() => _selection = null);
  }

  Future<void> _flipImage(bool horizontal) async {
    if (_state == null) return;
    final flat = await _flatten();
    final w = flat.width.toDouble(), h = flat.height.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    if (horizontal) { c.translate(w, 0); c.scale(-1, 1); } else { c.translate(0, h); c.scale(1, -1); }
    c.drawImage(flat, Offset.zero, Paint());
    final out = await rec.endRecording().toImage(flat.width, flat.height);
    _commit(_state!.copyWith(annotations: const [], image: out));
    setState(() => _selection = null);
  }

  /// Bounding box (image coords) of pixels differing from the top-left corner colour.
  Future<Rect?> _contentRect(ui.Image image) async {
    final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final b = bd.buffer.asUint8List();
    final w = image.width, h = image.height;
    int i(int x, int y) => (y * w + x) * 4;
    final br = b[0], bg = b[1], bb = b[2], ba = b[3];
    bool diff(int x, int y) {
      final k = i(x, y);
      return (b[k] - br).abs() + (b[k + 1] - bg).abs() + (b[k + 2] - bb).abs() + (b[k + 3] - ba).abs() > 30;
    }
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (diff(x, y)) { if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y; }
      }
    }
    if (maxX < minX || maxY < minY) return null;
    return Rect.fromLTRB(minX.toDouble(), minY.toDouble(), (maxX + 1).toDouble(), (maxY + 1).toDouble());
  }

  Future<void> _trim() async {
    if (_state == null) return;
    final flat = await _flatten();
    final rect = await _contentRect(flat);
    final full = Rect.fromLTWH(0, 0, flat.width.toDouble(), flat.height.toDouble());
    if (rect == null || rect == full) return;
    final cropped = await _cropImage(flat, rect);
    _commit(_state!.copyWith(annotations: const [], image: cropped));
    setState(() => _selection = null);
  }

  Future<void> _cropToCanvas() => _flattenInPlace(); // flatten clips everything to the canvas bounds

  Future<void> _resizeCanvasDialog() async {
    if (_state == null) return;
    final w0 = _state!.image.width, h0 = _state!.image.height;
    final wc = TextEditingController(text: '$w0'), hc = TextEditingController(text: '$h0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resize Canvas'),
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 80, child: TextField(controller: wc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Width'))),
          const SizedBox(width: 12),
          SizedBox(width: 80, child: TextField(controller: hc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Height'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Resize')),
        ],
      ),
    );
    if (ok != true) return;
    final w = (int.tryParse(wc.text) ?? w0).clamp(16, 10000);
    final h = (int.tryParse(hc.text) ?? h0).clamp(16, 10000);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(_state!.image, Offset.zero, Paint());
    final out = await rec.endRecording().toImage(w, h);
    _commit(_state!.copyWith(image: out)); // annotations keep their coordinates
  }

  Future<void> _changeCanvasColor() async {
    if (_state == null) return;
    final color = await _pickColor();
    if (color == null) return;
    // The canvas colour shows wherever the image doesn't cover the canvas (added space, transparent edges)
    _commit(_state!.copyWith(background: color));
  }

  Future<Color?> _pickColor() {
    final current = _state?.background.toARGB32();
    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Canvas Colour'),
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fills the canvas around and behind the image — resize the canvas (drag its square handles) to add space.',
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in const [Colors.white, Color(0xFFEEEEEE), Color(0xFF8E8E93), Colors.black, Color(0xFF1E1E2E), ..._palette])
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 30, height: 30,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.black26),
                        boxShadow: c.toARGB32() == current ? [BoxShadow(color: Theme.of(ctx).colorScheme.primary, spreadRadius: 2.5)] : null),
                  ),
                ),
            ]),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
  }

  Future<void> _showCanvasMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPos & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 'flipH', child: Text('Flip Horizontal')),
        PopupMenuItem(value: 'flipV', child: Text('Flip Vertically')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'trim', child: Text('Trim')),
        PopupMenuItem(value: 'cropCanvas', child: Text('Crop to Canvas')),
        PopupMenuItem(value: 'resize', child: Text('Resize Canvas…')),
        PopupMenuItem(value: 'color', child: Text('Change Canvas Colour…')),
        PopupMenuItem(value: 'flatten', child: Text('Flatten All')),
      ],
    );
    switch (sel) {
      case 'flipH': await _flipImage(true);
      case 'flipV': await _flipImage(false);
      case 'trim': await _trim();
      case 'cropCanvas': await _cropToCanvas();
      case 'resize': await _resizeCanvasDialog();
      case 'color': await _changeCanvasColor();
      case 'flatten': await _flattenInPlace();
    }
  }

  void _deleteSelection() {
    if (_selection == null) return;
    final anns = [for (final a in _state!.annotations) if (a.id != _selection) a];
    _commit(_state!.copyWith(annotations: anns));
    setState(() => _selection = null);
  }

  void _setTool(Tool t) {
    if (t == Tool.grabText) {
      _copyAllText();
      return;
    }
    setState(() { _tool = t; _selection = null; });
  }

  // ---- PanelHost (the properties panel) ----

  @override
  Annotation? get selected => _annotation(_selection);
  @override
  Tool get tool => _tool;
  @override
  Color get color => _color;
  @override
  StrokeSize get size => _size;

  @override
  StyleKind? get styleKind {
    final a = selected;
    return a != null ? a.styleKind : StyleKind.ofTool(_tool);
  }

  @override
  ArrowStyle get currentArrowStyle {
    final a = selected;
    if (a != null && a.styleKind != null) return a.arrowStyle;
    final k = styleKind;
    return k == null ? ArrowStyle.arrow : _styleFor(k);
  }

  @override
  bool get selectionIsCurved {
    final s = selected?.shape;
    return switch (s) { ArrowShape(:final bend) || LineShape(:final bend) => bend != Offset.zero, _ => false };
  }

  /// Color picks also restyle the selection.
  @override
  void pickColor(Color c, {bool refresh = true}) {
    setState(() => _color = c);
    final a = selected;
    if (a != null && a.shape is! ImageShape) _replace(a.copyWith(color: c));
  }

  @override
  void openColorPanel() => Native.showColorPanel(_color.toARGB32() & 0xFFFFFF);

  @override
  void pickSize(StrokeSize s) {
    setState(() => _size = s);
    final a = selected;
    if (a != null) _replace(a.copyWith(size: s));
  }

  /// Restyles the selection (undoable) and makes the style the default for its kind.
  @override
  void setArrowStyle(ArrowStyle style) {
    final k = styleKind;
    if (k == null) return;
    final a = selected;
    if (a != null && a.styleKind != null) _replace(a.copyWith(arrowStyle: style));
    setState(() => _styleDefaults[k] = style);
    Native.setDataString('style.${k.name}', jsonEncode(style.toJson()));
  }

  /// Color, size and style together: to the selection as one undo step, and as the defaults.
  @override
  void applyQuickStyle(QuickStyle q) {
    setState(() { _color = q.colorValue; _size = q.size; });
    final k = styleKind;
    if (k != null) {
      _styleDefaults[k] = q.style;
      Native.setDataString('style.${k.name}', jsonEncode(q.style.toJson()));
    }
    final a = selected;
    if (a == null) return;
    _replace(a.copyWith(color: q.colorValue, size: q.size, arrowStyle: a.styleKind != null ? q.style : null));
  }

  @override
  void straighten() {
    final a = selected;
    switch (a?.shape) {
      case ArrowShape(:final from, :final to):
        _replace(a!.copyWith(shape: ArrowShape(from, to)));
      case LineShape(:final from, :final to):
        _replace(a!.copyWith(shape: LineShape(from, to)));
      default:
        break;
    }
  }

  @override
  void resetStyle() {
    final k = styleKind;
    if (k != null) setArrowStyle(k.builtIn);
  }

  @override
  void copyAllText() => _copyAllText();

  @override
  Future<void> saveCurrentStyle() async {
    final a = selected;
    final kind = a != null ? QuickKind.of(a) : QuickKind.ofTool(_tool);
    if (kind == null) return;
    await QuickStyles.save(QuickStyle(_color.toARGB32() & 0xFFFFFF, _size, currentArrowStyle), kind);
    await QuickStyles.setCurrent(QuickStyles.mine);
    setState(() {});
    await Native.toast('Saved to My Styles', symbol: 'star.fill');
  }

  @override
  Future<void> clearSavedStyles() async {
    final a = selected;
    final kind = a != null ? QuickKind.of(a) : QuickKind.ofTool(_tool);
    if (kind == null) return;
    await QuickStyles.clear(kind);
    setState(() {});
  }

  @override
  void quickSetChanged() => setState(() {});

  // ---- UI ----

  /// Single-key tool shortcuts, as in the Swift app.
  static final _toolKeys = <LogicalKeyboardKey, Tool>{
    LogicalKeyboardKey.keyV: Tool.select, LogicalKeyboardKey.keyA: Tool.arrow, LogicalKeyboardKey.keyL: Tool.line,
    LogicalKeyboardKey.keyR: Tool.box, LogicalKeyboardKey.keyO: Tool.ellipse, LogicalKeyboardKey.keyP: Tool.pen,
    LogicalKeyboardKey.keyH: Tool.highlight, LogicalKeyboardKey.keyT: Tool.text, LogicalKeyboardKey.keyK: Tool.callout,
    LogicalKeyboardKey.keyN: Tool.step, LogicalKeyboardKey.keyB: Tool.blur, LogicalKeyboardKey.keyS: Tool.spotlight,
    LogicalKeyboardKey.keyC: Tool.crop, LogicalKeyboardKey.keyG: Tool.grabText,
  };

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undoAction,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _redoAction,
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copyImage,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): save,
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): openImageDialog,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): AppController.instance.onWindowClose,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): selectImage,
        const SingleActivator(LogicalKeyboardKey.delete): _deleteSelection,
        const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelection,
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _selection = null),
        for (final e in _toolKeys.entries) SingleActivator(e.key): () => _setTool(e.value),
      },
      child: Focus(focusNode: _focus, autofocus: true, child: _scaffold(state)),
    );
  }

  Widget _scaffold(CanvasState? state) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(children: [
        _toolbar(),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Container(
                color: dark ? const Color(0xFF1C1C1E) : const Color(0xFFE6E6E9),
                child: state == null ? const Center(child: CircularProgressIndicator()) : _canvasArea(state),
              ),
            ),
            PropertiesPanel(host: this),
          ]),
        ),
      ]),
    );
  }

  /// The canvas: the image centred with a soft shadow, and one full-size input/paint layer over the whole
  /// area, so the canvas handles (just outside the image) and drags past its edges work.
  Widget _canvasArea(CanvasState state) {
    return LayoutBuilder(builder: (context, constraints) {
      const pad = 20.0;
      final iw = state.image.width.toDouble(), ih = state.image.height.toDouble();
      final scale = math.max(0.01, math.min(math.min((constraints.maxWidth - pad * 2) / iw, (constraints.maxHeight - pad * 2) / ih), 1.0));
      _viewScale = scale;
      final fitted = Size(iw * scale, ih * scale);
      final origin = Offset((constraints.maxWidth - fitted.width) / 2, (constraints.maxHeight - fitted.height) / 2);
      Offset toImage(Offset local) => (local - origin) / scale;
      final kind = StyleKind.ofTool(_tool);
      return DragTarget<String>(
        // A filmstrip thumbnail dropped anywhere over the canvas area
        onWillAcceptWithDetails: (d) => !d.data.toLowerCase().endsWith('.mov') && !d.data.toLowerCase().endsWith('.mp4'),
        onAcceptWithDetails: (d) => addOverlayFile(d.data, globalPosition: d.offset + const Offset(64, 48)),
        builder: (context, candidates, _) => Container(
          decoration: candidates.isEmpty ? null : BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2)),
          child: Stack(children: [
            Positioned(
              left: origin.dx, top: origin.dy, width: fitted.width, height: fitted.height,
              child: Container(
                key: _canvasKey,
                decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 3))]),
              ),
            ),
            Positioned.fill(
              child: MouseRegion(
                cursor: _tool == Tool.select ? SystemMouseCursors.basic : SystemMouseCursors.precise,
                child: GestureDetector(
                  onSecondaryTapUp: (d) => _showCanvasMenu(d.globalPosition),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) { _focus.requestFocus(); if (e.buttons == 1) _down(toImage(e.localPosition)); },
                    onPointerMove: (e) => _move(toImage(e.localPosition)),
                    onPointerUp: (e) => _up(toImage(e.localPosition)),
                    child: CustomPaint(
                      painter: _PreviewPainter(
                        base: CanvasPainter(state: state, selectionId: _selection, scale: scale),
                        origin: origin,
                        tool: _tool, color: _color, size: _size, scale: scale,
                        style: kind == null ? ArrowStyle.arrow : _styleFor(kind),
                        createStart: _createStart, createCurrent: _createCurrent, penPoints: _penPoints,
                        canvasChrome: _showsCanvasHandles || _canvasDrag != null,
                        ants: _copied ? _ants : null,
                        canvasResize: _canvasDrag?.$2,
                        boundsOfSelection: selected == null || selected!.rect != null ? null : _bounds(selected!),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }

  static const _toolInfo = <Tool, (IconData, String)>{
    Tool.select: (Icons.near_me_outlined, 'Select'),
    Tool.arrow: (Icons.north_east, 'Arrow'),
    Tool.text: (Icons.text_fields, 'Text'),
    Tool.callout: (Icons.chat_bubble_outline, 'Callout'),
    Tool.box: (Icons.crop_square, 'Box'),
    Tool.ellipse: (Icons.circle_outlined, 'Ellipse'),
    Tool.line: (Icons.horizontal_rule, 'Line'),
    Tool.pen: (Icons.gesture, 'Pen'),
    Tool.step: (Icons.looks_one_outlined, 'Step'),
    Tool.highlight: (Icons.border_color_outlined, 'Highlight'),
    Tool.blur: (Icons.blur_on, 'Blur'),
    Tool.spotlight: (Icons.flashlight_on_outlined, 'Spotlight'),
    Tool.crop: (Icons.crop, 'Crop'),
  };

  Widget _toolbar() {
    final shown = [for (final t in _toolOrder) if (_visibleTools.contains(t)) t];
    final hidden = [for (final t in _toolOrder) if (!_visibleTools.contains(t)) t];
    final moreActive = hidden.contains(_tool);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final t in shown)
                _ToolButton(icon: _toolInfo[t]!.$1, label: _toolInfo[t]!.$2, active: _tool == t, onTap: () => _setTool(t)),
              _MoreButton(
                active: moreActive,
                label: moreActive ? _toolInfo[_tool]!.$2 : 'More',
                icon: moreActive ? _toolInfo[_tool]!.$1 : Icons.expand_more,
                items: [
                  for (final t in hidden) (t.name, _toolInfo[t]!.$1, _toolInfo[t]!.$2),
                  if (hidden.isNotEmpty) null,
                  ('open', Icons.folder_open_outlined, 'Open Image…'),
                  ('overlay', Icons.add_photo_alternate_outlined, 'Add Image…'),
                  ('flatten', Icons.layers_clear_outlined, 'Flatten All'),
                  ('export', Icons.ios_share, 'Save As…'),
                  ('settings', Icons.settings_outlined, 'Settings…'),
                ],
                onSelected: (v) {
                  final t = Tool.values.where((t) => t.name == v).firstOrNull;
                  if (t != null) return _setTool(t);
                  switch (v) {
                    case 'open': openImageDialog();
                    case 'overlay': _addOverlay();
                    case 'flatten': _flattenInPlace();
                    case 'export': _exportPng();
                    case 'settings': Native.shell('settings');
                  }
                },
              ),
            ]),
          ),
        ),
        _ToolButton(icon: Icons.undo, label: 'Undo', onTap: _undo.isEmpty ? null : _undoAction),
        _ToolButton(icon: Icons.redo, label: 'Redo', onTap: _redo.isEmpty ? null : _redoAction),
        const SizedBox(width: 6),
        _ToolButton(icon: Icons.document_scanner_outlined, label: 'Copy Text', onTap: _copyAllText),
        _ToolButton(icon: Icons.folder_outlined, label: 'Finder', onTap: _path == null ? null : () => Native.reveal(_path!)),
        _ToolButton(icon: Icons.content_copy, label: 'Copy', onTap: _copyImage),
        _ToolButton(icon: Icons.save_outlined, label: 'Save', onTap: save, primary: hasUnsavedChanges),
      ]),
    );
  }
}

/// A toolbar button with the icon over its label (the Swift app's toolbar look); the active tool
/// gets an accent bar underneath.
class _ToolButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active, primary;
  final VoidCallback? onTap;
  const _ToolButton({required this.icon, required this.label, this.active = false, this.primary = false, this.onTap});
  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    final fg = !enabled ? s.onSurface.withValues(alpha: 0.3)
        : widget.active || widget.primary ? s.primary : _hover ? s.onSurface : s.onSurfaceVariant;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 54),
          height: 50,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _hover && enabled && !widget.active ? s.surfaceContainerHighest.withValues(alpha: 0.7) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(widget.icon, size: 20, color: fg),
              const SizedBox(height: 3),
              Text(widget.label, style: TextStyle(fontSize: 10.5, color: fg, fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400)),
            ]),
            if (widget.active)
              Positioned(left: 8, right: 8, bottom: 0,
                  child: Container(height: 2, decoration: BoxDecoration(color: s.primary, borderRadius: BorderRadius.circular(1)))),
          ]),
        ),
      ),
    );
  }
}

/// "More ▾": hidden tools and less-used actions.
class _MoreButton extends StatelessWidget {
  final bool active;
  final String label;
  final IconData icon;
  final List<(String, IconData, String)?> items;
  final ValueChanged<String> onSelected;
  const _MoreButton({required this.active, required this.label, required this.icon, required this.items, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final i in items)
          if (i == null)
            const PopupMenuDivider(height: 8)
          else
            PopupMenuItem(value: i.$1, height: 32, child: Row(children: [
              Icon(i.$2, size: 17), const SizedBox(width: 10), Text(i.$3, style: const TextStyle(fontSize: 13)),
            ])),
      ],
      child: IgnorePointer(child: _ToolButton(icon: icon, label: '$label ▾', active: active, onTap: () {})),
    );
  }
}

/// Paints the committed state plus the in-progress gesture (drawn with the real style) and the canvas
/// chrome: the image's dashed border and square handles when it is selected, marching ants after Copy,
/// and the new outline while the canvas is being resized. `origin` is where the image sits in the area.
class _PreviewPainter extends CustomPainter {
  final CanvasPainter base;
  final Offset origin;
  final Tool tool;
  final Color color;
  final StrokeSize size;
  final ArrowStyle style;
  final double scale;
  final Offset? createStart, createCurrent;
  final List<Offset>? penPoints;
  final bool canvasChrome;
  final ValueNotifier<double>? ants;
  final Rect? canvasResize;
  final Rect? boundsOfSelection;

  _PreviewPainter({required this.base, required this.origin, required this.tool, required this.color, required this.size,
      required this.scale, required this.style, this.createStart, this.createCurrent, this.penPoints,
      this.canvasChrome = false, this.ants, this.canvasResize, this.boundsOfSelection})
      : super(repaint: ants);

  static const _accent = Color(0xFF2F7CF6);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    final imageSize = Size(base.state.image.width * scale, base.state.image.height * scale);
    canvas.save();
    canvas.clipRect(Offset.zero & imageSize, doAntiAlias: false); // annotations stay on the image
    base.paint(canvas, imageSize);
    canvas.restore();
    base.paintSelection(canvas); // handles may sit on the edge, so outside the clip

    canvas.save();
    canvas.scale(scale);
    Annotation ann(Shape s) => Annotation(id: -1, shape: s, color: color, size: this.size, arrowStyle: style, scale: base.state.density);
    if (penPoints != null && penPoints!.length > 1) {
      CanvasPainter.drawAnnotation(canvas, ann(PenShape(penPoints!)));
    } else if (createStart != null && createCurrent != null) {
      final a = createStart!, b = createCurrent!, r = Rect.fromPoints(a, b);
      switch (tool) {
        case Tool.arrow:
          CanvasPainter.drawAnnotation(canvas, ann(ArrowShape(a, b)));
        case Tool.line:
          CanvasPainter.drawAnnotation(canvas, ann(LineShape(a, b)));
        case Tool.box:
          CanvasPainter.drawAnnotation(canvas, ann(RectShape(r)));
        case Tool.ellipse:
          CanvasPainter.drawAnnotation(canvas, ann(EllipseShape(r)));
        case Tool.highlight:
          CanvasPainter.drawAnnotation(canvas, ann(HighlightShape(r)));
        case Tool.blur:
          CanvasPainter.drawAnnotation(canvas, ann(BlurShape(r, null)), base: base.state.image);
        case Tool.callout:
          // Where the pointer will point, and a line to where the bubble will go
          final line = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2 / scale;
          canvas.drawPath(CanvasPainter.dashed(Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy), [6 / scale, 4 / scale]), line);
          canvas.drawCircle(a, 4 / scale, Paint()..color = color);
        case Tool.spotlight || Tool.crop:
          final dim = Path()..addRect(Offset.zero & Size(base.state.image.width.toDouble(), base.state.image.height.toDouble()))
            ..addRect(r)..fillType = PathFillType.evenOdd;
          canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.45));
          canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5 / scale);
        default:
          break;
      }
    }
    canvas.restore();

    // Selected text, callouts and steps have no handles: a dashed box shows they are selected
    if (boundsOfSelection != null) {
      final r = Rect.fromLTRB(boundsOfSelection!.left * scale, boundsOfSelection!.top * scale,
          boundsOfSelection!.right * scale, boundsOfSelection!.bottom * scale).inflate(4);
      _border(canvas, r, 0, accent: true);
    }

    final frame = Offset.zero & imageSize;
    final resize = canvasResize;
    if (resize != null) {
      final target = Rect.fromLTRB(resize.left * scale, resize.top * scale, resize.right * scale, resize.bottom * scale);
      canvas.drawPath(Path()..addRect(target)..addRect(frame)..fillType = PathFillType.evenOdd,
          Paint()..color = Colors.white.withValues(alpha: 0.85)); // new white space (and what will be cut)
      final keep = target.intersect(frame);
      canvas.drawPath(Path()..addRect(frame)..addRect(keep)..fillType = PathFillType.evenOdd,
          Paint()..color = Colors.black.withValues(alpha: 0.4)); // area that will be cropped away
      _border(canvas, target, 0, accent: true);
    } else if (canvasChrome) {
      _border(canvas, frame.inflate(1), ants?.value ?? 0);
      for (final h in CanvasPainter.rectHandles(frame.inflate(4))) {
        final sq = Rect.fromCenter(center: h, width: 7, height: 7);
        canvas.drawRect(sq, Paint()..color = Colors.white);
        canvas.drawRect(sq, Paint()..color = const Color(0xFF737373)..style = PaintingStyle.stroke..strokeWidth = 1);
      }
    }
    canvas.restore();
  }

  /// A one-point dashed line, white under dark gray (or the accent): marching ants when `phase` moves.
  static void _border(Canvas canvas, Rect rect, double phase, {bool accent = false}) {
    final r = rect.deflate(0.5);
    canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1);
    canvas.drawPath(CanvasPainter.dashed(Path()..addRect(r), const [4, 4], phase: phase),
        Paint()..color = accent ? _accent : const Color(0xFF333333)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) => true;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
