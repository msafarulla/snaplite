import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/manim/manim_doc.dart';

void main() {
  test('formulas: math in, Python out, nothing else gets through', () {
    expect(Formula.eval('x^2 - 1', 3), 8);
    expect(Formula.eval('2*sin(pi/2)', 0), closeTo(2, 1e-9));
    expect(Formula.eval('-x^2', 2), -4, reason: 'unary minus binds looser than ^');
    expect(Formula.toPython('x^2 + 3*x'), 'x ** 2 + 3 * x');
    for (final bad in ["__import__('os')", 'x; import os', 'os.system(1)', 'x)', 'exec(x)', 'x # c', '']) {
      expect(Formula.toPython(bad), isNull, reason: bad);
    }
  });

  test('code: every kind, in timeline order, with its animation', () {
    final d = ManimDoc();
    MItem add(MKind k, {String text = '', MEnter? enter}) {
      final i = MItem(id: d.newId(), kind: k, text: text, enter: enter);
      d.items.add(i);
      return i;
    }
    add(MKind.text, text: 'Say "hi"');
    add(MKind.math, text: r'e^{i\pi} + 1 = 0');
    add(MKind.math, text: r'\frac{a}{b}', enter: MEnter.transform);
    add(MKind.rect);
    add(MKind.arrow);
    add(MKind.graph, text: 'x^2');
    add(MKind.dot).emphasis = MEmphasis.indicate;
    add(MKind.image).image = Uint8List.fromList([1, 2, 3]);
    final code = d.code();
    for (final s in ['Text("Say \\"hi\\""', r'MathTex(r"e^{i\pi} + 1 = 0"', 'ReplacementTransform(m2, m3)', 'Rectangle(',
      'Arrow(', 'plot(lambda x: x ** 2, x_range=', 'Indicate(m7)', 'ImageMobject("image_8.png")']) {
      expect(code, contains(s), reason: s);
    }
    expect(code.indexOf('Text('), lessThan(code.indexOf('Rectangle(')));
    expect(code, contains('FadeOut(m) for m in [m1, m3,'), reason: 'the replaced math is gone, so not faded again');
    expect(d.files.keys, ['image_8.png']);
  });

  test('a formula that fails the check never reaches the code', () {
    final d = ManimDoc()..items.add(MItem(id: 1, kind: MKind.graph, text: "__import__('os').system('x')"));
    expect(d.code(), isNot(contains('__import__')));
  });

  test('projects save and open with everything, images included', () {
    final d = ManimDoc(background: const Color(0xFF102030))
      ..items.add(MItem(id: 4, kind: MKind.image, image: Uint8List.fromList([9, 8, 7]), pos: const Offset(1, -2)))
      ..items.add(MItem(id: 5, kind: MKind.text, text: 'Hi', emphasis: MEmphasis.wiggle, runTime: 2));
    final back = ManimDoc.decode(d.encode());
    expect(back.background, const Color(0xFF102030));
    expect(back.items.first.image, [9, 8, 7]);
    expect(back.items.first.pos, const Offset(1, -2));
    expect(back.items.last.emphasis, MEmphasis.wiggle);
    expect(back.newId(), 6, reason: 'new ids continue after the saved ones');
  });

  test('together, camera, curves, braces, motion and exits become the right Manim', () {
    final d = ManimDoc();
    MItem add(MKind k, {String text = ''}) {
      final i = MItem(id: d.newId(), kind: k, text: text);
      d.items.add(i);
      return i;
    }
    add(MKind.rect).zoom = true;
    add(MKind.circle).withPrevious = true;
    add(MKind.brace, text: 'width').braceDir = MBraceDir.up;
    add(MKind.arrow)..curve = 90..doubleHead = true..rate = MRate.bounce;
    add(MKind.star)..motion = MMotion.rotate..rotateBy = 180..exit = MExit.shrink;
    final code = d.code();
    expect(code, contains('class SnapStudio(MovingCameraScene):'));
    expect(RegExp(r'self\.play\(Create\(m1\), Create\(m2\), run_time=').hasMatch(code), isTrue, reason: 'started together');
    expect(code, contains('self.play(Restore(self.camera.frame)'), reason: 'the camera comes back after the zoom');
    expect(code, contains('Brace(m2, direction=UP'), reason: 'braces wrap the object before them');
    expect(code, contains('CurvedDoubleArrow('));
    expect(code, contains('rate_func=rate_functions.ease_out_bounce'));
    expect(code, contains('Rotate(m5, angle=3.142)'));
    expect(code, contains('ShrinkToCenter(m5)'));
    expect(code, isNot(contains('FadeOut(m) for m in [m1, m2, m3, m4, m5]')), reason: 'what left already isn\'t faded again');
  });

  test('version 1 projects (before curves and motion) still open', () {
    final old = '{"format":"snapnow-manim","version":1,"items":[{"id":3,"kind":"arrow","pos":[0,0],"end":[1,1],"enter":"create"}]}';
    final d = ManimDoc.decode(old);
    expect(d.items.single.curve, 0);
    expect(d.items.single.exit, MExit.none);
    expect(d.code(), contains('Arrow('));
  });
}
