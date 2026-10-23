import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/main.dart';

void main() {
  testWidgets('App builds', (tester) async {
    await tester.pumpWidget(const SnapLiteApp());
    expect(find.byType(SnapLiteApp), findsOneWidget);
  });
}
