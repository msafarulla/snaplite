import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Bridge to the platform layer (macOS: macos/Runner/SnapLiteNative.swift).
class Native {
  static const _ch = MethodChannel('snaplite/native');
  static void Function(String? path)? onRecordingFinished;
  static void Function(String path)? onOpenEditor;
  static void Function()? onShowLibrary;
  static void Function()? onCapturesChanged;
  static void Function(String choice)? onAppearanceChanged;

  static void init() {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'recordingFinished': onRecordingFinished?.call(call.arguments as String?);
        case 'openEditor': onOpenEditor?.call(call.arguments as String);
        case 'showLibrary': onShowLibrary?.call();
        case 'capturesChanged': onCapturesChanged?.call();
        case 'colorPicked': onColorPicked?.call(call.arguments as int);
        case 'appearanceChanged': onAppearanceChanged?.call(call.arguments as String);
      }
    });
  }

  /// Runs one of the menu bar shell's flows: region, window, screen, text, record, library, openImage, settings.
  static Future<void> shell(String action) => _call('shell', {'action': action});
  /// Clipboard + toast preview, like Copy Text everywhere else.
  static Future<void> copyText(String text) => _call('copyText', {'text': text});
  static Future<void> toast(String message, {String symbol = 'checkmark.circle.fill'}) =>
      _call('toast', {'message': message, 'symbol': symbol});
  static Future<List<int>?> toolbarTools() async => (await _call<List>('toolbarTools'))?.cast<int>();

  static Future<Uint8List?> thumbnail(String path, {double size = 180}) =>
      _call<Uint8List>('thumbnail', {'path': path, 'size': size});
  static Future<void> trash(List<String> paths) => _call('trash', {'paths': paths});
  static Future<void> copyFiles(List<String> paths) => _call('copyFiles', {'paths': paths});
  static Future<void> copyTextOfFile(String path) => _call('copyTextOfFile', {'path': path});
  static Future<String?> exportGif(String path) => _call<String>('exportGIF', {'path': path});
  /// Save panel with a Format menu (PNG, JPEG, HEIC, TIFF, PDF, GIF, BMP); returns the saved path,
  /// null when cancelled, and throws a PlatformException when writing fails.
  static Future<String?> saveAs(Uint8List png, {required String name, double density = 1}) =>
      _call<String>('saveAs', {'png': png, 'name': name, 'density': density});

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!Platform.isMacOS) return null;
    return _ch.invokeMethod<T>(method, args);
  }

  /// action -> stored JSON {keyCode, modifiers} written by either app version.
  static Future<Map<String, String>> storedShortcuts() async =>
      Map<String, String>.from(await _call<Map>('storedShortcuts') ?? const {});
  static Future<void> setShortcut(String action, String? json) => _call('setShortcut', {'action': action, 'json': json});

  /// UserDefaults Data written by the Swift app's JSONEncoder (style.arrow, myQuickStyles, …) as a string.
  static Future<String?> getDataString(String key) => _call<String>('getDataString', {'key': key});
  static Future<void> setDataString(String key, String json) => _call('setDataString', {'key': key, 'json': json});
  static Future<String?> getString(String key) => _call<String>('getString', {'key': key});
  static Future<void> setString(String key, String value) => _call('setString', {'key': key, 'value': value});

  /// The system color panel; picks arrive (continuously) through [onColorPicked] as 0xRRGGBB.
  static void Function(int rgb)? onColorPicked;
  static Future<void> showColorPanel(int rgb) => _call('showColorPanel', {'color': rgb});

  static Future<bool?> getBool(String key) => _call<bool>('getBool', {'key': key});
  static Future<void> setBool(String key, bool value) => _call('setBool', {'key': key, 'value': value});

  static Future<bool> screenAccess() async => await _call<bool>('screenAccess') ?? true;
  static Future<bool> requestScreenAccess() async => await _call<bool>('requestScreenAccess') ?? true;

  /// Cocoa global rect [x, y, w, h], or null when cancelled.
  static Future<List<double>?> selectRegion(String hint) async =>
      (await _call<List>('selectRegion', {'hint': hint}))?.cast<double>();

  /// "started", "cancelled" or "failed"; the movie arrives through [onRecordingFinished].
  static Future<String> startRecording({required bool microphone, bool showClicks = true}) async =>
      await _call<String>('startRecording', {'microphone': microphone, 'showClicks': showClicks}) ?? 'failed';
  static Future<void> stopRecording() => _call('stopRecording');

  /// Pixels per point from the image's DPI (144 dpi → 2), or null when the file doesn't say.
  static Future<double?> imageDensity(String path) => _call<double>('imageDensity', {'path': path});

  static Future<String> ocr(String path) async => await _call<String>('ocr', {'path': path}) ?? '';
  static Future<int> displayUnderMouse() async => await _call<int>('displayUnderMouse') ?? 1;

  static Future<void> reveal(String path) => _call('reveal', {'path': path});
  static Future<void> openPath(String path) => _call('openPath', {'path': path});
  static Future<void> activate() => _call('activate');
  static Future<void> beep() => _call('beep');
}
