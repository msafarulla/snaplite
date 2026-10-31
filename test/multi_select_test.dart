import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Multi-select (⌘A = same shapes) and the shape clipboard (⌘X / ⌘C / ⌘V / ⌘D), working on the group.
void main() {
  Future<void> pressCmd(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(k);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
  }

  /// Builds the editor, draws two boxes and one arrow, selects the first box and ⌘A-groups the boxes.
  /// Returns the state key and the canvas rect.
  Future<(GlobalKey<EditorPageState>, Rect)> setUpGroupedBoxes(WidgetTester tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (_) async => null);
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
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));

    await tester.tap(find.text('Shape').first);
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(200, 150), const Offset(150, 100));
    await tester.pump();
    await tester.tap(find.text('Shape').first);
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(500, 150), const Offset(140, 100));
    await tester.pump();
    await tester.tap(find.text('Arrow').first);
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(300, 450), const Offset(160, 0));
    await tester.pump();

    await tester.tap(find.text('Select').first);
    await tester.pump();
    await tester.tapAt(area.topLeft + const Offset(200, 200)); // first box's left edge
    await tester.pump();
    await pressCmd(tester, LogicalKeyboardKey.keyA);
    return (key, area);
  }

  testWidgets('⌘A selects same shapes; delete removes the group but leaves other kinds', (tester) async {
    final (key, _) = await setUpGroupedBoxes(tester);
    expect(key.currentState!.annotationCount, 3, reason: 'two boxes and an arrow');
    expect(key.currentState!.groupCount, 1, reason: 'the second box joins; the arrow is a different shape');
    key.currentState!.runMenu('delete');
    await tester.pump();
    expect(key.currentState!.annotationCount, 1, reason: 'both boxes gone, arrow left');
    expect(key.currentState!.groupCount, 0, reason: 'group cleared after delete');
  });

  testWidgets('⌘D duplicates the group, ⌘X cuts, ⌘V pastes', (tester) async {
    final (key, _) = await setUpGroupedBoxes(tester);
    await pressCmd(tester, LogicalKeyboardKey.keyD); // duplicate the two boxes
    expect(key.currentState!.annotationCount, 5, reason: 'two copies added');
    expect(key.currentState!.groupCount, 1, reason: 'the two copies are now selected');
    await pressCmd(tester, LogicalKeyboardKey.keyX); // cut the two copies
    expect(key.currentState!.annotationCount, 3, reason: 'cut removed the copies');
    await pressCmd(tester, LogicalKeyboardKey.keyV); // paste them back
    expect(key.currentState!.annotationCount, 5, reason: 'paste restored the two shapes');
  });
}
