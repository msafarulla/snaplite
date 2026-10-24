import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Zoom: pinch, ⌘-keys and the corner pill all share one view transform with drawing and hit-testing.
void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  Future<EditorPageState> pumpEditor(WidgetTester tester) async {
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
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return key.currentState!;
  }

  /// The image point under a canvas-area point, per the editor's current transform.
  Offset imageAt(EditorPageState e, Offset areaPoint) => (areaPoint - e.viewOrigin) / e.viewScale;

  Future<void> cmd(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
  }

  testWidgets('trackpad pinch zooms in and out around the fingers', (tester) async {
    final editor = await pumpEditor(tester);
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final fingers = area.topLeft + Offset(area.width * 0.35, area.height * 0.4);
    final local = fingers - area.topLeft;
    final fitScale = editor.viewScale;
    final under = imageAt(editor, local);
    expect(find.text('Fit'), findsOneWidget);

    final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await g.panZoomStart(fingers);
    await g.panZoomUpdate(fingers, scale: 1.5);
    await tester.pump();
    await g.panZoomUpdate(fingers, scale: 2.0);
    await tester.pump();
    await g.panZoomEnd();
    await tester.pump();

    expect(editor.viewScale, closeTo(fitScale * 2, 1e-6), reason: 'pinch out = zoom in');
    final after = imageAt(editor, local);
    expect((after - under).distance, lessThan(0.5), reason: 'the point under the fingers stays put');
    expect(find.text('${editor.zoomPercent.round()}%'), findsOneWidget);

    final g2 = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await g2.panZoomStart(fingers);
    await g2.panZoomUpdate(fingers, scale: 0.5);
    await tester.pump();
    await g2.panZoomEnd();
    await tester.pump();
    expect(editor.viewScale, closeTo(fitScale, 1e-6), reason: 'pinch in = zoom out');
  });

  testWidgets('two-finger scroll pans a zoomed image; ⌘0 fits, ⌘1 is 100%, ⌘= / ⌘- step', (tester) async {
    final editor = await pumpEditor(tester);
    final fit = editor.viewScale;
    await cmd(tester, LogicalKeyboardKey.equal);
    expect(editor.viewScale, closeTo(fit * 1.25, 1e-6));
    await cmd(tester, LogicalKeyboardKey.digit1);
    expect(editor.zoomPercent, closeTo(100, 1e-6));
    await cmd(tester, LogicalKeyboardKey.equal);
    await cmd(tester, LogicalKeyboardKey.equal);
    await cmd(tester, LogicalKeyboardKey.equal);

    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final before = editor.viewOrigin;
    final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await g.panZoomStart(area.center);
    await g.panZoomUpdate(area.center, pan: const Offset(-40, -30));
    await tester.pump();
    await g.panZoomEnd();
    await tester.pump();
    expect(editor.viewOrigin, isNot(before), reason: 'scrolling moves the zoomed image');

    await cmd(tester, LogicalKeyboardKey.minus);
    await cmd(tester, LogicalKeyboardKey.digit0);
    expect(editor.viewScale, closeTo(fit, 1e-6));
    expect(find.text('Fit'), findsOneWidget);
  });

  testWidgets('drawing still lands where clicked when zoomed', (tester) async {
    final editor = await pumpEditor(tester);
    await cmd(tester, LogicalKeyboardKey.digit1);
    await cmd(tester, LogicalKeyboardKey.equal);
    await tester.tap(find.text('Box'));
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final start = area.topLeft + const Offset(400, 300);
    final expected = imageAt(editor, const Offset(400, 300));
    await tester.dragFrom(start, const Offset(120, 80));
    await tester.pump();
    final r = editor.selected!.rect!;
    expect((r.topLeft - expected).distance, lessThan(2), reason: 'the box starts under the pointer');
    expect(r.width, closeTo(120 / editor.viewScale, 2));
  });
}
