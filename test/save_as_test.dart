import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Save As hands the flattened PNG to the native panel, which picks the format (PNG, PDF, JPEG, …).
void main() {
  final calls = <MethodCall>[];
  Object? Function(MethodCall)? saveAsReply;

  setUp(() {
    calls.clear();
    saveAsReply = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      calls.add(call);
      return call.method == 'saveAs' ? saveAsReply?.call(call) : null;
    });
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

  Future<void> shiftCmdS(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  testWidgets('Shift+Cmd+S sends the flattened PNG to the format panel and confirms the saved file', (tester) async {
    await pumpEditor(tester);
    saveAsReply = (_) => '/tmp/Shot.pdf';
    await tester.tap(find.byKey(const ValueKey('snaplite-canvas')));
    await shiftCmdS(tester);

    final save = calls.where((c) => c.method == 'saveAs').single;
    final args = save.arguments as Map;
    final png = args['png'] as Uint8List;
    expect(png.sublist(1, 4), 'PNG'.codeUnits, reason: 'the flattened canvas goes over as PNG bytes');
    expect(args['name'], 'SnapLite', reason: 'an unsaved canvas gets a default name');
    expect(args['density'], isA<double>());
    final toast = calls.where((c) => c.method == 'toast').last.arguments as Map;
    expect(toast['message'], 'Saved Shot.pdf');
  });

  testWidgets('a cancelled panel saves nothing; a failed write shows the error', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('snaplite-canvas')));
    await shiftCmdS(tester); // reply null = cancelled
    expect(calls.where((c) => c.method == 'toast'), isEmpty);

    saveAsReply = (_) => throw PlatformException(code: 'write', message: "Couldn't save as HEIC");
    await shiftCmdS(tester);
    final toast = calls.where((c) => c.method == 'toast').single.arguments as Map;
    expect(toast['message'], "Couldn't save as HEIC");
    expect(toast['symbol'], 'exclamationmark.triangle.fill');
  });
}
