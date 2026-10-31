import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

void main() {
  testWidgets('reducing pixels keeps the on-screen footprint (grainy, not smaller)', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 1400, height: 1000, child: EditorPage(key: key))),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400)); // _makeBlankCanvas(1200,800) completes
    });
    await tester.pump();
    void drain() { while (tester.takeException() != null) {} } // ignore unrelated panel-overflow noise
    drain();

    expect(key.currentState!.debugOriginalSize, const Size(1200, 800), reason: 'original size recorded on create');
    final scaleBefore = key.currentState!.debugViewScale;
    final footprintBefore = 1200 * scaleBefore;

    await tester.runAsync(() => key.currentState!.scaleCanvasTo(480, 320)); // reduce the pixels
    await tester.pump();
    drain();
    final scaleAfter = key.currentState!.debugViewScale;
    final footprintAfter = 480 * scaleAfter;

    expect(scaleAfter, greaterThan(scaleBefore), reason: 'fewer pixels are drawn larger (grainy), not smaller');
    expect(footprintAfter, closeTo(footprintBefore, 1.0),
        reason: 'the image occupies the same on-screen size after reducing pixels');
  });

  testWidgets('a width-only pixel change does not stretch the height', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 1400, height: 1000, child: EditorPage(key: key))),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    void drain() { while (tester.takeException() != null) {} }
    drain();

    final s = key.currentState!;
    final wBefore = 1200 * s.debugViewScale, hBefore = 800 * s.debugViewScaleY;

    await tester.runAsync(() => s.scaleCanvasTo(600, 800)); // halve the WIDTH only, keep the height
    await tester.pump();
    drain();
    final wAfter = 600 * s.debugViewScale, hAfter = 800 * s.debugViewScaleY;

    expect(hAfter, closeTo(hBefore, 1.0), reason: 'height on screen is unchanged (it was being stretched)');
    expect(wAfter, closeTo(wBefore, 1.0), reason: 'width on screen is unchanged too (just grainier)');
  });
}
