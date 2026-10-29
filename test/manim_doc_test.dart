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
}
