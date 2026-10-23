import 'package:flutter/material.dart';
import 'app/app_controller.dart';
import 'library/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppController.instance.init();
  runApp(const SnapLiteApp());
}

class SnapLiteApp extends StatelessWidget {
  const SnapLiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapLite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B8EEA), useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3B8EEA), useMaterial3: true, brightness: Brightness.dark),
      home: LibraryPage(key: AppController.instance.libraryKey),
    );
  }
}
