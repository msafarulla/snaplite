import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'native.dart';

/// The global shortcuts, stored exactly like the Swift app did (UserDefaults "shortcut.<action>",
/// JSON {keyCode, modifiers} with Carbon key codes and modifier masks), so settings carry over.
enum ShortcutAction {
  region('Capture Area'),
  window('Capture Window'),
  screen('Capture Screen'),
  text('Copy Text'),
  record('Record Screen'),
  library('Library');

  const ShortcutAction(this.title);
  final String title;

  /// ⌃⇧ + C / W / F / T / R / O, as in the Swift app.
  Shortcut get defaultShortcut => Shortcut(const {
        ShortcutAction.region: 8, ShortcutAction.window: 13, ShortcutAction.screen: 3,
        ShortcutAction.text: 17, ShortcutAction.record: 15, ShortcutAction.library: 31,
      }[this]!, Shortcut.control | Shortcut.shift);
}

class Shortcut {
  // Carbon modifier masks
  static const cmd = 256, shift = 512, option = 2048, control = 4096;

  final int keyCode; // Carbon virtual key code (same numbering as macOS key codes)
  final int modifiers;
  const Shortcut(this.keyCode, this.modifiers);

  bool get isCleared => keyCode < 0;

  String get label {
    var s = '';
    if (modifiers & control != 0) s += '⌃';
    if (modifiers & option != 0) s += '⌥';
    if (modifiers & shift != 0) s += '⇧';
    if (modifiers & cmd != 0) s += '⌘';
    return s + (keyNames[keyCode] ?? '?');
  }

  /// Carbon key code -> label (release builds strip Flutter's key debug names).
  static const keyNames = {
    0: 'A', 11: 'B', 8: 'C', 2: 'D', 14: 'E', 3: 'F', 5: 'G', 4: 'H', 34: 'I', 38: 'J', 40: 'K', 37: 'L', 46: 'M',
    45: 'N', 31: 'O', 35: 'P', 12: 'Q', 15: 'R', 1: 'S', 17: 'T', 32: 'U', 9: 'V', 13: 'W', 7: 'X', 16: 'Y', 6: 'Z',
    29: '0', 18: '1', 19: '2', 20: '3', 21: '4', 23: '5', 22: '6', 26: '7', 28: '8', 25: '9',
    27: '-', 24: '=', 33: '[', 30: ']', 41: ';', 39: "'", 43: ',', 47: '.', 44: '/', 42: '\\', 50: '`',
    49: 'Space', 36: '↩', 48: '⇥', 123: '←', 124: '→', 125: '↓', 126: '↑',
    122: 'F1', 120: 'F2', 99: 'F3', 118: 'F4', 96: 'F5', 97: 'F6', 98: 'F7', 100: 'F8', 101: 'F9', 109: 'F10',
    103: 'F11', 111: 'F12',
  };

  HotKey? toHotKey(String id) {
    final key = kMacOsToPhysicalKey[keyCode];
    if (key == null) return null;
    return HotKey(identifier: id, key: key, scope: HotKeyScope.system, modifiers: [
      if (modifiers & control != 0) HotKeyModifier.control,
      if (modifiers & option != 0) HotKeyModifier.alt,
      if (modifiers & shift != 0) HotKeyModifier.shift,
      if (modifiers & cmd != 0) HotKeyModifier.meta,
    ]);
  }

  String toJson() => jsonEncode({'keyCode': keyCode, 'modifiers': modifiers});
}

class HotkeyStore {
  /// The effective shortcut per action (null = cleared by the user).
  static Future<Map<ShortcutAction, Shortcut?>> load() async {
    final stored = await Native.storedShortcuts();
    final out = <ShortcutAction, Shortcut?>{};
    for (final a in ShortcutAction.values) {
      final raw = stored[a.name];
      Shortcut? s = a.defaultShortcut;
      if (raw != null) {
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          s = Shortcut(m['keyCode'] as int, m['modifiers'] as int);
          if (s.isCleared) s = null;
        } catch (_) {}
      }
      out[a] = s;
    }
    return out;
  }

  static Future<void> save(ShortcutAction a, Shortcut? s) =>
      Native.setShortcut(a.name, (s ?? const Shortcut(-1, 0)).toJson());
}
