import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/app/app_controller.dart';
import 'package:snaplite_flutter/main.dart';

void main() {
  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      m.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  testWidgets('the Library and editor follow Settings › Appearance live', (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (d) { if (!d.exceptionAsString().contains('overflowed')) original?.call(d); };
    addTearDown(() => FlutterError.onError = original);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark; // the Mac is in dark mode
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final appearance = AppController.instance.appearance;

    appearance.value = 'light';
    await tester.pumpWidget(const SnapLiteApp());
    await tester.pump();
    BuildContext ctx() => tester.element(find.byType(Scaffold).first);
    expect(Theme.of(ctx()).brightness, Brightness.light, reason: 'Light even though the Mac is dark');

    appearance.value = 'tokyoNight';
    await tester.pumpAndSettle();
    expect(Theme.of(ctx()).brightness, Brightness.dark);
    expect(Theme.of(ctx()).colorScheme.primary, const Color(0xFF7AA2F7), reason: 'Tokyo Night colours');

    appearance.value = 'glass';
    await tester.pumpAndSettle();
    expect(Theme.of(ctx()).brightness, Brightness.dark, reason: 'Glass follows the Mac');
    appearance.value = 'glass';
  });
}
