import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Captures stay as they are: transparent parts (a window's rounded corners) are not filled white.
void main() {
  /// A 100×60 red window with fully transparent corners.
  Future<ui.Image> window() async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 60), const Radius.circular(14)),
        Paint()..color = Colors.red);
    return rec.endRecording().toImage(100, 60);
  }

  Future<int> alphaAt(ui.Image img, int x, int y) async {
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    return px.getUint8((y * img.width + x) * 4 + 3);
  }

  test('a new canvas is transparent; a picked colour still fills it', () {
    expect(const CanvasState(image: _NoImage()).background.a, 0);
  });

  testWidgets('the flattened picture keeps transparent corners', (tester) async {
    await tester.runAsync(() async {
      final s = CanvasState(image: await window());
      final rec = ui.PictureRecorder();
      CanvasPainter(state: s, selectionId: null, scale: 1).paint(Canvas(rec), const Size(100, 60));
      final flat = await rec.endRecording().toImage(100, 60);
      expect(await alphaAt(flat, 0, 0), 0, reason: 'corner left transparent');
      expect(await alphaAt(flat, 50, 30), 255);

      final white = s.copyWith(background: Colors.white);
      final rec2 = ui.PictureRecorder();
      CanvasPainter(state: white, selectionId: null, scale: 1).paint(Canvas(rec2), const Size(100, 60));
      expect(await alphaAt(await rec2.endRecording().toImage(100, 60), 0, 0), 255, reason: 'a chosen canvas colour fills it');
    });
  });

  testWidgets('the GIF keeps transparent corners', (tester) async {
    await tester.runAsync(() async {
      final s = CanvasState(image: await window(), annotations: [
        Annotation(id: 1, shape: const ArrowShape(Offset(20, 30), Offset(80, 30)),
            arrowStyle: const ArrowStyle(pattern: LinePattern.ants, shadow: false)),
      ]);
      final codec = await ui.instantiateImageCodec(await BuildUpGif.renderMarching(s));
      final frame = (await codec.getNextFrame()).image;
      expect(await alphaAt(frame, 0, 0), 0);
      expect(await alphaAt(frame, frame.width ~/ 2, 5), 255);
    });
  });

  testWidgets('⌘C copies a PNG with the transparent corners', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (call) async {
      if (call.method == 'writeImage') copied = call.arguments as Uint8List;
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

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final png = (await (await window()).toByteData(format: ui.ImageByteFormat.png))!;
      final file = File('${Directory.systemTemp.createTempSync().path}/window.png')..writeAsBytesSync(png.buffer.asUint8List());
      await key.currentState!.openFile(file.path);
    });
    await tester.pump();
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    expect(copied, isNotNull);
    final img = await tester.runAsync(() async => (await (await ui.instantiateImageCodec(copied!)).getNextFrame()).image);
    expect(await tester.runAsync(() => alphaAt(img!, 0, 0)), 0);
    await tester.pumpWidget(const SizedBox());
  });
}

class _NoImage implements ui.Image {
  const _NoImage();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
