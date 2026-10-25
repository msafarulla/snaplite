import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

void main() {
  testWidgets('⌃⌘C with no markup copies the finished PNG as a still sticker', (tester) async {
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

  testWidgets('⌃⌘C with markup sends the build-up animation to the WhatsApp sticker pack', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[], sent = <Map>[];
    var notInstalled = false;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'toast') toasts.add(args!['message'] as String);
      if (call.method == 'addWhatsAppSticker') {
        if (notInstalled) throw PlatformException(code: 'whatsapp', message: "WhatsApp isn't installed");
        sent.add(args!);
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
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.center - const Offset(150, -100), const Offset(250, -150));
    await tester.pump();

    Future<void> press() => tester.runAsync(() async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await Future<void>.delayed(const Duration(seconds: 3)); // frames render off the test clock
        });

    await press();
    expect(toasts.last, startsWith('Sent to WhatsApp'));
    final frames = sent.single['frames'] as Uint8List, durations = (sent.single['durations'] as List).cast<int>();
    const frameBytes = 512 * 512 * 4;
    expect(frames.length, frameBytes * durations.length, reason: 'full 512×512 RGBA frames');
    expect(durations.length, greaterThan(2), reason: 'animated');
    expect(durations.fold(0, (a, b) => a + b), lessThanOrEqualTo(10000), reason: "WhatsApp's 10 s limit");
    expect(frames[3], 0, reason: 'transparent corner');
    expect(frames[(256 * 512 + 256) * 4 + 3], 255, reason: 'the picture in the middle');
    expect(frames.sublist(0, frameBytes), isNot(frames.sublist(frames.length - frameBytes)), reason: 'the arrow appears');

    notInstalled = true;
    await press();
    expect(toasts.last, "WhatsApp isn't installed");
  });
}
