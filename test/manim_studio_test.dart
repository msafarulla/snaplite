import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/manim/manim_doc.dart';
import 'package:snaplite_flutter/manim/manim_studio_page.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('studio-test-');
    ManimStudioPage.projectsFolderOverride = tmp.path;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ManimStudioPageState> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) { if (!d.toString().contains('overflowed')) original!(d); };
    addTearDown(() => FlutterError.onError = original);
    await t.pumpWidget(const MaterialApp(home: ManimStudioPage()));
    await t.pump();
    return t.state<ManimStudioPageState>(find.byType(ManimStudioPage));
  }

  testWidgets('a new project starts with a title; objects add, select, move and save themselves', (t) async {
    final s = await pump(t);
    expect(s.doc.items.single.kind, MKind.text, reason: 'starter title, so Render works at once');

    await t.tap(find.text('Rectangle'));
    await t.pump();
    final rect = s.doc.items.last;
    expect(rect.kind, MKind.rect);
    expect(s.selected, rect.id, reason: 'a new object is selected for editing');
    expect(find.text('ANIMATION'), findsOneWidget, reason: 'its properties show');

    // Drag it on the stage: right and up in scene units
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    final ppu = stage.height / ManimDoc.frameH;
    final at = stage.topLeft + Offset((rect.pos.dx / ManimDoc.frameW + 0.5) * stage.width, (0.5 - rect.pos.dy / ManimDoc.frameH) * stage.height);
    final before = rect.pos;
    await t.dragFrom(at, Offset(ppu * 2, -ppu));
    await t.pump();
    expect(rect.pos.dx - before.dx, closeTo(2, 0.3));
    expect(rect.pos.dy - before.dy, closeTo(1, 0.3));

    await t.pump(const Duration(seconds: 1)); // the save timer
    final saved = tmp.listSync().whereType<File>().where((f) => f.path.endsWith('.snapmanim')).single;
    expect(ManimDoc.decode(saved.readAsStringSync()).items.length, 2, reason: 'saved without asking');
    expect(s.doc.code(), contains('Rectangle('));
  });
}
