import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// The Share button sits on the canvas: clicking it opens the share menu under it with the finished picture,
/// and doesn't draw on the canvas underneath.
void main() {
  testWidgets('Share on the canvas opens the share menu under the button, without drawing', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final shares = <Map>[];
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'share') shares.add(call.arguments as Map);
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
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(300, 300), const Offset(200, -120));
    await tester.pump();
    final before = key.currentState!.state!.annotations.length;
    expect(before, 1);

    final button = find.text('Share');
    expect(button, findsOneWidget);
    final pill = tester.getRect(find.ancestor(of: button, matching: find.byType(Material)).first);
    await tester.runAsync(() async {
      await tester.tap(button);
      for (var i = 0; i < 50 && shares.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();

    expect(shares, hasLength(1));
    expect(File(shares.single['path'] as String).existsSync(), isTrue, reason: 'the finished picture as a file');
    expect((shares.single['x'] as num).toDouble(), closeTo(pill.left, 1), reason: 'the menu opens at the button');
    expect((shares.single['y'] as num).toDouble(), closeTo(pill.top, 1));
    expect(key.currentState!.state!.annotations.length, before, reason: 'clicking Share draws nothing');
  });
}
