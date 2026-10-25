import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

void main() {
  testWidgets('⌃⌘C hands the finished PNG to the native sticker encoder', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[], stickers = <Map>[];
    var pngCopies = 0, fail = false;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (call) async {
      if (call.method == 'writeImage') pngCopies++;
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'toast') toasts.add(args!['message'] as String);
      if (call.method == 'copySticker') {
        if (fail) throw PlatformException(code: 'sticker');
        stickers.add(args!);
        return '/tmp/SnapLite Stickers/SnapLite.webp';
      }
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

    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: EditorPage()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    Future<void> press() => tester.runAsync(() async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });

    await press();
    expect(toasts.last, 'Copied sticker');
    final png = stickers.single['png'] as Uint8List;
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: 'a PNG');
    expect(stickers.single['name'], 'SnapLite');
    expect(pngCopies, 0, reason: 'not the ⌘C still');

    fail = true;
    await press();
    expect(toasts.last, "Couldn't make the sticker");
  });
}
