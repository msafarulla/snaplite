import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'app/app_controller.dart';
import 'library/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // file_picker's macOS panels refuse to open without sandbox file entitlements; SnapLite isn't sandboxed
  // (it runs /usr/sbin/screencapture), so that check only gets in the way of Open / Add Image / GIF save.
  if (Platform.isMacOS) await FilePicker.skipEntitlementsChecks();
  await AppController.instance.init();
  runApp(const SnapLiteApp());
}

class SnapLiteApp extends StatelessWidget {
  const SnapLiteApp({super.key});

  static const _accent = Color(0xFF2F7CF6);

  static final _light = ThemeData(colorSchemeSeed: _accent, useMaterial3: true, brightness: Brightness.light);
  static final _dark = ThemeData(colorSchemeSeed: _accent, useMaterial3: true, brightness: Brightness.dark);

  /// Matches the Ghostty terminal (tokyonight + FiraMono), like the Swift app's Tokyo Night theme.
  static final _tokyoNight = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'FiraMono Nerd Font Mono',
    scaffoldBackgroundColor: const Color(0xFF1A1B26),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF7AA2F7),
      onPrimary: Color(0xFF1A1B26),
      secondary: Color(0xFFBB9AF7),
      surface: Color(0xFF1A1B26),
      onSurface: Color(0xFFC0CAF5),
      onSurfaceVariant: Color(0xFFA9B1D6),
      surfaceContainerLow: Color(0xFF16161E),
      surfaceContainer: Color(0xFF16161E),
      surfaceContainerHigh: Color(0xFF24283B),
      surfaceContainerHighest: Color(0xFF292E42),
      outline: Color(0xFF565F89),
      outlineVariant: Color(0xFF2F334D),
      error: Color(0xFFF7768E),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Follows Settings › Appearance live: Light / Dark / Tokyo Night as chosen; Glass and Match System follow the Mac
    return ValueListenableBuilder<String>(
      valueListenable: AppController.instance.appearance,
      builder: (context, choice, _) => MaterialApp(
        title: 'SnapLite',
        debugShowCheckedModeBanner: false,
        theme: _light,
        darkTheme: choice == 'tokyoNight' ? _tokyoNight : _dark,
        themeMode: switch (choice) {
          'light' => ThemeMode.light,
          'dark' || 'tokyoNight' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: LibraryPage(key: AppController.instance.libraryKey),
      ),
    );
  }
}
