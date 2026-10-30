import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    await t.tap(find.text('Shapes ▾'));
    await t.pumpAndSettle();
    await t.tap(find.text('Rectangle').last);
    await t.pumpAndSettle();
    expect(s.tool, MKind.rect, reason: 'picking a shape arms it for drawing');
    expect(s.doc.items.length, 1, reason: 'nothing is dropped until you draw');

    // Draw it: a drag from the stage centre 4 units right and 2 down
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    final ppu = stage.height / ManimDoc.frameH;
    await t.dragFrom(stage.center, Offset(ppu * 4, ppu * 2));
    await t.pump();
    final rect = s.doc.items.last;
    expect(rect.kind, MKind.rect);
    expect(rect.size.width, closeTo(4, 0.3));
    expect(rect.size.height, closeTo(2, 0.3));
    expect(rect.pos.dx, closeTo(2, 0.3), reason: 'it fills the dragged box');
    expect(rect.pos.dy, closeTo(-1, 0.3));
    expect(s.selected, rect.id, reason: 'a new object is selected for editing');
    expect(find.text('ANIMATION'), findsOneWidget, reason: 'its properties show');

    // Esc puts the tool down; then dragging the rectangle moves it: right and up in scene units
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(s.tool, isNull);
    s.selected = rect.id;
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

  testWidgets('a curved arrow from the toolbar; its curve and animations are editable', (t) async {
    final s = await pump(t);
    await t.tap(find.text('Curved'));
    await t.pump();
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    await t.dragFrom(stage.center - const Offset(150, 0), const Offset(300, -80));
    await t.pumpAndSettle();
    final arrow = s.doc.items.last;
    expect(arrow.kind, MKind.arrow);
    expect(arrow.curve, 60);
    final ppu = stage.height / ManimDoc.frameH;
    expect((arrow.end - arrow.pos).dx, closeTo(300 / ppu, 0.3), reason: 'it runs where you dragged');
    expect((arrow.end - arrow.pos).dy, closeTo(80 / ppu, 0.3));
    expect(find.text('Curve'), findsOneWidget, reason: 'the curve slider shows');
    expect(find.text('Start together with the previous one'), findsOneWidget);
    expect(find.text('Zoom the camera to it'), findsOneWidget);
    expect(s.doc.code(), contains('CurvedArrow('));
  });

  testWidgets('a click with a tool armed drops one at its default size there', (t) async {
    final s = await pump(t);
    await t.tap(find.text('Arrow'));
    await t.pump();
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    await t.tapAt(stage.center);
    await t.pump();
    final arrow = s.doc.items.last;
    expect(arrow.kind, MKind.arrow);
    expect((arrow.end - arrow.pos).distance, closeTo(3, 0.01));
    expect(((arrow.pos + arrow.end) / 2).distance, lessThan(0.1), reason: 'centred where you clicked');
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('a star drawn up and to the left stays regular; a tiny drag gets the default size', (t) async {
    final s = await pump(t);
    await t.tap(find.text('Shapes ▾'));
    await t.pumpAndSettle();
    await t.tap(find.text('Star').last);
    await t.pumpAndSettle();
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    final ppu = stage.height / ManimDoc.frameH;
    await t.dragFrom(stage.center, Offset(-ppu * 3, -ppu * 1));
    await t.pump();
    final star = s.doc.items.last;
    expect(star.kind, MKind.star);
    expect(star.size.width, closeTo(3, 0.3));
    expect(star.size.height, star.size.width, reason: 'regular, the longer side wins');
    expect(star.pos.dx, closeTo(-1.5, 0.3), reason: 'grows toward the drag (left)');
    expect(star.pos.dy, closeTo(1.5, 0.3), reason: 'and up');

    final g = await t.startGesture(stage.center + Offset(ppu * 3, 0));
    await g.moveBy(const Offset(25, 0)); // past the drag slop, but under the size threshold
    await g.moveBy(const Offset(1, 0));
    await g.up();
    await t.pump();
    final small = s.doc.items.last;
    expect(small.id, isNot(star.id));
    expect(small.size, const Size(2.2, 2.2), reason: 'a drag too short to mean a size');
    expect(small.pos.dx, closeTo(3, 0.3));
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('the Arrow tool follows the drag: a curvy drag is an arrow along that path', (t) async {
    final s = await pump(t);
    await t.tap(find.text('Arrow'));
    await t.pump();
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    final g = await t.startGesture(stage.center - const Offset(200, 0));
    for (var k = 1; k <= 20; k++) {
      await g.moveTo(stage.center + Offset(-200 + k * 20.0, -120 * math.sin(k / 20 * math.pi)));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final arrow = s.doc.items.last;
    expect(arrow.kind, MKind.path, reason: 'drawn along the drag, not a stock arrow');
    expect(arrow.arrowTip, isTrue);
    expect(arrow.closed, isFalse);
    expect(arrow.enter, MEnter.create, reason: 'it draws itself on');
    final code = s.doc.code();
    expect(code, contains('m${arrow.id}.set_points_smoothly('));
    expect(code, contains('add_tip('));
    expect(s.tool, MKind.arrow, reason: 'the tool stays for the next one');
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('Draw: a stroke on the stage becomes a drawing (arrowhead, Fourier Draw)', (t) async {
    final s = await pump(t);
    await t.tap(find.byKey(const ValueKey('studio-draw')));
    await t.pump();
    expect(s.drawMode, isTrue);
    final stage = t.getRect(find.byKey(const ValueKey('studio-stage')));
    final g = await t.startGesture(stage.center - const Offset(200, 0));
    for (var k = 1; k <= 40; k++) {
      await g.moveTo(stage.center + Offset(-200 + k * 10.0, 60 * (k.isEven ? 1 : 0.6) * (k % 8 < 4 ? 1 : -1)));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final drawing = s.doc.items.last;
    expect(drawing.kind, MKind.path);
    expect(drawing.points.length, inInclusiveRange(3, 120), reason: 'smoothed and thinned');
    expect(drawing.arrowTip, isTrue, reason: 'an open stroke ends in an arrowhead');
    expect(drawing.enter, MEnter.fourier);
    expect(find.text('Circles'), findsOneWidget, reason: 'Fourier settings show');
    final code = s.doc.code();
    expect(code, contains('def snapnow_fourier('));
    expect(code, contains('snapnow_fourier(self, m${drawing.id},'));
    expect(code, contains('add_tip('));
    await t.pump(const Duration(seconds: 1)); // the auto-save
  });
}
