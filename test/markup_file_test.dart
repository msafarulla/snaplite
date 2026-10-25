import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';
import 'package:snaplite_flutter/model/markup_file.dart';

/// Markup kept inside the saved PNG: reopening brings back the capture and every annotation, in order.
void main() {
  Future<ui.Image> blank(int w, int h, Color c) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = c);
    return rec.endRecording().toImage(w, h);
  }

  Future<Uint8List> png(ui.Image i) async => (await i.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

  /// One of every kind, in an order that isn't id order (z-order and creation order differ).
  Future<CanvasState> everything() async {
    final overlay = await blank(30, 20, Colors.blue);
    return CanvasState(
      image: await blank(400, 300, Colors.white),
      density: 2,
      background: const Color(0xFF112233),
      annotations: [
        const Annotation(id: 7, shape: ArrowShape(Offset(10, 10), Offset(200, 120),
            points: [Offset(80, 30)], tangents: [null, Offset(1, 0.5), null]),
            arrowStyle: ArrowStyle(end: ArrowHead.swept, tapered: true, width: 6), scale: 2),
        const Annotation(id: 2, shape: LineShape(Offset(5, 5), Offset(50, 60)), size: StrokeSize.large),
        const Annotation(id: 3, shape: RectShape(Rect.fromLTRB(20, 20, 120, 90)), color: Color(0xFF00FF00)),
        const Annotation(id: 4, shape: EllipseShape(Rect.fromLTRB(30, 30, 90, 70))),
        const Annotation(id: 5, shape: HighlightShape(Rect.fromLTRB(0, 100, 200, 120))),
        const Annotation(id: 6, shape: SpotlightShape(Rect.fromLTRB(50, 50, 150, 150))),
        const Annotation(id: 1, shape: BlurShape(Rect.fromLTRB(300, 10, 380, 40), null)),
        const Annotation(id: 8, shape: PenShape([Offset(1, 2), Offset(3, 4), Offset(5, 7)])),
        const Annotation(id: 9, shape: TextShape('Héllo ✓', Offset(40, 200),
            runs: [TextRun(0, 2, (color: Color(0xFFFF0000), bold: true, italic: null, underline: null))]),
            textFormat: TextFormat(family: 'Menlo', points: 20, italic: true, align: TextAlign.center)),
        const Annotation(id: 10, shape: CalloutShape('Click here', Offset(220, 200), tail: Offset(260, 150)),
            textFormat: TextFormat(textColor: Color(0xFF000000))),
        const Annotation(id: 11, shape: CalloutShape('No pointer', Offset(10, 250))),
        const Annotation(id: 12, shape: StepShape(Offset(350, 250))),
        Annotation(id: 13, shape: ImageShape(const Rect.fromLTWH(300, 200, 60, 40), overlay)),
      ],
    );
  }

  testWidgets('every kind of annotation survives a save and reopen', (tester) async {
    await tester.runAsync(() async {
      final s = await everything();
      final flat = await png(s.image); // stands in for the flattened picture
      final saved = await MarkupFile.embed(flat, s);
      final back = (await MarkupFile.read(saved))!;

      expect(back.density, 2);
      expect(back.background, const Color(0xFF112233));
      expect((back.image.width, back.image.height), (400, 300));
      expect([for (final a in back.annotations) a.id], [for (final a in s.annotations) a.id], reason: 'z-order and ids kept');

      final arrow = back.annotations[0];
      expect(arrow.curve, [const Offset(10, 10), const Offset(80, 30), const Offset(200, 120)]);
      expect(arrow.curveTangents, [null, const Offset(1, 0.5), null]);
      expect(arrow.arrowStyle, const ArrowStyle(end: ArrowHead.swept, tapered: true, width: 6));
      expect(arrow.scale, 2);
      expect(back.annotations[1].size, StrokeSize.large);
      expect(back.annotations[2].color, const Color(0xFF00FF00));
      expect(back.annotations[2].rect, const Rect.fromLTRB(20, 20, 120, 90));
      expect(back.annotations[6].shape, isA<BlurShape>());
      expect((back.annotations[7].shape as PenShape).points.last, const Offset(5, 7));
      final text = back.annotations[8];
      expect((text.shape as TextShape).string, 'Héllo ✓');
      expect((text.shape as TextShape).runs, s.annotations[8].shape is TextShape ? (s.annotations[8].shape as TextShape).runs : null);
      expect(text.textFormat, const TextFormat(family: 'Menlo', points: 20, italic: true, align: TextAlign.center));
      expect((back.annotations[9].shape as CalloutShape).tail, const Offset(260, 150));
      expect(back.annotations[9].textFormat.textColor, const Color(0xFF000000));
      expect((back.annotations[10].shape as CalloutShape).tail, isNull);
      expect((back.annotations[11].shape as StepShape).center, const Offset(350, 250));
      final img = back.annotations[12].shape as ImageShape;
      expect((img.image.width, img.image.height), (30, 20));
      expect(img.rect, const Rect.fromLTWH(300, 200, 60, 40));

      final again = await MarkupFile.embed(saved, back);
      expect(again.length, saved.length, reason: 'saving again replaces the markup instead of adding a second copy');
    });
  });

  testWidgets('anything off opens the file flat', (tester) async {
    await tester.runAsync(() async {
      final s = await everything();
      final flat = await png(s.image);
      final saved = await MarkupFile.embed(flat, s);

      expect(await MarkupFile.read(flat), isNull, reason: 'a plain PNG has no markup');
      expect(await MarkupFile.embed(flat, s.copyWith(annotations: const [])), flat, reason: 'nothing to keep');

      Uint8List flipped(int at) => Uint8List.fromList(saved)..[at] ^= 0x01;
      final chunk = _find(saved, 'snLP');
      expect(await MarkupFile.read(flipped(chunk + 20)), isNull, reason: 'damaged markup (checksum)');
      final idat = _find(saved, 'IDAT');
      expect(await MarkupFile.read(flipped(idat + 10)), isNull, reason: 'a damaged file');

      // Another app redrew the picture but carried the chunk along: its markup no longer matches.
      final other = await png(await blank(400, 300, Colors.black));
      final transplanted = _withChunkFrom(other, saved);
      expect(await MarkupFile.read(transplanted), isNull);

      // A newer format this version doesn't know.
      final newer = Uint8List.fromList(saved)..[chunk + 8] = MarkupFile.version + 1;
      _fixCrc(newer, chunk);
      expect(await MarkupFile.read(newer), isNull);

      expect(await MarkupFile.read(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  testWidgets('a capture saved with markup reopens editable, and ⇧⌘C still makes the GIF', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[], copiedGifs = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'toast') toasts.add(args!['message'] as String);
      if (call.method == 'copyGif') copiedGifs.add(args!['path'] as String);
      return null;
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final dir = Directory.systemTemp.createTempSync('snaplite_markup');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = '${dir.path}/Capture.png';
    await tester.runAsync(() async => File(file).writeAsBytes(await png(await blank(800, 500, Colors.white))));

    var key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await key.currentState!.openFile(file);
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    await tester.tap(find.text('Box'));
    await tester.pump();
    await tester.dragFrom(area.center + const Offset(-300, -200), const Offset(150, 100));
    await tester.pump();
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.center + const Offset(0, 150), const Offset(200, -120));
    await tester.pump();
    final drawn = key.currentState!.state!.annotations;
    expect(drawn.length, 2);
    await tester.runAsync(() => key.currentState!.save());

    // A fresh editor, as if days later
    key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await key.currentState!.openFile(file);
    });
    await tester.pump();
    final reopened = key.currentState!.state!;
    expect([for (final a in reopened.annotations) a.shape.runtimeType], [RectShape, ArrowShape]);
    expect(reopened.annotations[1].curve, drawn[1].curve);
    final pixels = await tester.runAsync(() async =>
        (await reopened.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List());
    expect(pixels!.every((p) => p == 0xFFFFFFFF), isTrue, reason: 'the original capture, without the markup baked in');
    expect(key.currentState!.hasUnsavedChanges, isFalse);

    await tester.runAsync(() async {
      await key.currentState!.copyAnimatedGif();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    expect(toasts.last, 'Copied GIF');
    final codec = await tester.runAsync(() async => ui.instantiateImageCodec(await File(copiedGifs.single).readAsBytes()));
    expect(codec!.frameCount, greaterThan(2), reason: 'animated, from markup saved earlier');

    // New annotations after reopening don't reuse saved ids
    await tester.tap(find.text('Step'));
    await tester.pump();
    await tester.tapAt(area.center + const Offset(300, -200));
    await tester.pump();
    final ids = [for (final a in key.currentState!.state!.annotations) a.id];
    expect(ids.toSet().length, ids.length);
  });
}

int _find(Uint8List png, String type) {
  final d = ByteData.sublistView(png);
  var p = 8;
  while (p < png.length) {
    if (String.fromCharCodes(png.sublist(p + 4, p + 8)) == type) return p;
    p += 12 + d.getUint32(p);
  }
  throw StateError('no $type');
}

void _fixCrc(Uint8List png, int at) {
  final d = ByteData.sublistView(png);
  final len = d.getUint32(at);
  var c = 0xFFFFFFFF;
  for (var i = at + 4; i < at + 8 + len; i++) {
    c ^= png[i];
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  d.setUint32(at + 8 + len, c ^ 0xFFFFFFFF);
}

/// `target` with `source`'s snLP chunk copied in before IEND.
Uint8List _withChunkFrom(Uint8List target, Uint8List source) {
  final s = _find(source, 'snLP');
  final chunk = source.sublist(s, s + 12 + ByteData.sublistView(source).getUint32(s));
  final iend = _find(target, 'IEND');
  return Uint8List.fromList([...target.sublist(0, iend), ...chunk, ...target.sublist(iend)]);
}
