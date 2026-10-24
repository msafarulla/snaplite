import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/export/gif_encoder.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The build-up GIF: original capture, then each annotation appearing in turn, decoded back by the engine.
void main() {
  Future<List<(Uint32List, Duration)>> decode(Uint8List gif) async {
    final codec = await ui.instantiateImageCodec(gif);
    final out = <(Uint32List, Duration)>[];
    for (var i = 0; i < codec.frameCount; i++) {
      final f = await codec.getNextFrame();
      final data = await f.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      out.add((data!.buffer.asUint32List(), f.duration));
    }
    return out;
  }

  int rgba(int r, int g, int b) => 0xFF000000 | (b << 16) | (g << 8) | r; // little-endian RGBA bytes

  test('encoder: sub-frames draw over the last frame, transparent pixels keep it, delays survive', () async {
    final red = Uint32List(4 * 3)..fillRange(0, 12, rgba(255, 0, 0));
    final patch = Uint32List.fromList([0, rgba(0, 0, 255), rgba(0, 0, 255), 0]); // 2×2, two kept pixels
    final gif = encodeGif(4, 3, [
      GifFrame(0, 0, 4, 3, red.buffer.asUint8List(), 1000),
      GifFrame(1, 1, 2, 2, patch.buffer.asUint8List(), 250),
    ]);
    final frames = await decode(gif);
    expect(frames.length, 2);
    expect(frames[0].$2, const Duration(milliseconds: 1000));
    expect(frames[1].$2, const Duration(milliseconds: 250));
    final last = frames[1].$1;
    expect(last[1 * 4 + 1], rgba(255, 0, 0), reason: 'transparent pixel shows the frame before');
    expect(last[1 * 4 + 2], rgba(0, 0, 255));
    expect(last[2 * 4 + 1], rgba(0, 0, 255));
    expect(last[0], rgba(255, 0, 0), reason: 'outside the patch is untouched');
  });

  test('encoder: a busy picture (thousands of colours, LZW table resets) comes back close', () async {
    const w = 320, h = 200;
    final px = Uint32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        px[y * w + x] = rgba(x * 255 ~/ w, y * 255 ~/ h, (x * y) % 256);
      }
    }
    final frames = await decode(encodeGif(w, h, [GifFrame(0, 0, w, h, px.buffer.asUint8List(), 100)]));
    final back = frames.single.$1;
    var worst = 0;
    for (var i = 0; i < px.length; i++) {
      for (var c = 0; c < 3; c++) {
        final d = ((px[i] >> (8 * c)) & 0xFF) - ((back[i] >> (8 * c)) & 0xFF);
        if (d.abs() > worst) worst = d.abs();
      }
    }
    expect(worst, lessThan(64), reason: '255 colours for a full gradient: banding, but no garbage');
  });

  testWidgets('painter: an arrow half-way through appearing is drawn from its tail only', (tester) async {
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 200, 60), Paint()..color = Colors.white);
      final base = await rec.endRecording().toImage(200, 60);
      final state = CanvasState(image: base, annotations: const [
        Annotation(id: 1, shape: ArrowShape(Offset(20, 30), Offset(180, 30))),
      ]);
      Future<Uint32List> shot(Map<int, double>? p) async {
        final r = ui.PictureRecorder();
        CanvasPainter(state: state, selectionId: null, scale: 1, progress: p).paint(Canvas(r), const Size(200, 60));
        final img = await r.endRecording().toImage(200, 60);
        return (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List();
      }

      final hidden = await shot({}), half = await shot({1: 0.5}), full = await shot(null);
      final white = rgba(255, 255, 255);
      int at(Uint32List p, int x) => p[30 * 200 + x];
      expect(at(hidden, 100), white, reason: 'progress 0 hides it');
      expect(at(half, 40), isNot(white), reason: 'the tail end is drawn');
      expect(at(half, 170), white, reason: 'the head end is not there yet');
      expect(at(full, 170), isNot(white));
    });
  });

  testWidgets('Save as Animated GIF: original first, one appearance per addition, finished picture held', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[];
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'toast') toasts.add((call.arguments as Map)['message'] as String);
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
    final dir = Directory.systemTemp.createTempSync('snaplite_gif');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/Shot.gif';
    EditorPageState.pickGifPath = (name) async => out.replaceFirst('Shot.gif', name);
    addTearDown(() => EditorPageState.pickGifPath = (_) async => null);

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));

    await tester.runAsync(() => key.currentState!.saveAnimatedGif());
    expect(toasts.last, 'Add some markup first');

    await tester.tap(find.text('Box'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(200, 150), const Offset(150, 100));
    await tester.pump();
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(500, 400), const Offset(200, -120));
    await tester.pump();

    EditorPageState.pickGifPath = (_) async => throw PlatformException(code: 'ENTITLEMENT_NOT_FOUND');
    await tester.runAsync(() => key.currentState!.saveAnimatedGif());
    expect(toasts.last, "Couldn't make the GIF", reason: 'a panel that fails to open says so instead of doing nothing');

    EditorPageState.pickGifPath = (name) async => out.replaceFirst('Shot.gif', name);
    await tester.runAsync(() => key.currentState!.saveAnimatedGif());
    expect(toasts.last, 'Saved SnapLite.gif');
    final frames = await tester.runAsync(() async => decode(await File('${dir.path}/SnapLite.gif').readAsBytes()));
    final white = rgba(255, 255, 255);
    expect(frames!.first.$1.every((p) => p == white), isTrue, reason: 'starts on the original (blank) capture');
    expect(frames.first.$2, BuildUpGif.openingHold);
    final perShape = 600 * BuildUpGif.fps ~/ 1000;
    expect(frames.length, 1 + 2 * perShape, reason: 'every frame of both appearances changes something');
    expect(frames.last.$2, BuildUpGif.finalHold + const Duration(milliseconds: 600 ~/ (600 * BuildUpGif.fps ~/ 1000)));
  });
}
