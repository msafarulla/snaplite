import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The quick-style tiles draw the shape in use: Ellipse tiles are ellipses, not boxes.
void main() {
  testWidgets('shape tiles follow the Box / Ellipse / Pen tool', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final c in ['window_manager', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
    }
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
    });
    await tester.pump();
    Set<Tool> samples() => {
          for (final p in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
            if (p.painter.runtimeType.toString() == '_TilePainter') (p.painter as dynamic).sample as Tool,
        };
    // Shortcuts, since Ellipse and Pen are off the toolbar by default
    for (final (k, tool) in [(LogicalKeyboardKey.keyR, Tool.box), (LogicalKeyboardKey.keyO, Tool.ellipse), (LogicalKeyboardKey.keyP, Tool.pen)]) {
      await tester.sendKeyEvent(k);
      await tester.pump();
      expect(samples(), {tool}, reason: '${tool.name} tiles');
    }
    await tester.pumpWidget(const SizedBox());
  });
}
