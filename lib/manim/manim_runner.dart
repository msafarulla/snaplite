import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../app/app_controller.dart';

/// Finds the Manim installed on this Mac and renders scenes with it into the captures folder (so results show
/// in the Library). SnapNow doesn't ship Manim; README › Manim Studio has the one-time install.
class ManimRunner {
  /// Where SnapNow looks, in order: its own install, then the usual places.
  static final candidates = [
    '${Platform.environment['HOME']}/.local/share/snapnow/manim/bin/manim',
    '/opt/homebrew/bin/manim',
    '/usr/local/bin/manim',
    '${Platform.environment['HOME']}/.local/bin/manim',
  ];

  /// Homebrew and TeX first on PATH: a GUI app's PATH has neither, and Manim calls ffmpeg and latex.
  static Map<String, String> get env => {
        'PATH': '/opt/homebrew/bin:/usr/local/bin:/Library/TeX/texbin:'
            '${Platform.environment['HOME']}/Library/TinyTeX/bin/universal-darwin:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
      };

  /// The first Manim that runs, and its version (shown, so it's clear which program renders the code).
  static Future<({String path, String version})?> find() async {
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        final r = await Process.run(path, ['--version'], environment: env);
        final v = '${r.stdout}'.trim().split('\n').last.trim();
        if (r.exitCode == 0 && v.isNotEmpty) return (path: path, version: v);
      } catch (_) {}
    }
    return null;
  }

  /// Whether LaTeX is installed (Manim's MathTex needs `latex` and `dvisvgm`).
  static Future<bool> hasLatex() async {
    try {
      final r = await Process.run('/bin/sh', ['-c', 'command -v latex && command -v dvisvgm'], environment: env);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static const installHelp = 'Manim isn\'t installed. In Terminal:\n'
      '  brew install cairo pango pkgconf python@3.13\n'
      '  /opt/homebrew/opt/python@3.13/bin/python3.13 -m venv ~/.local/share/snapnow/manim\n'
      '  ~/.local/share/snapnow/manim/bin/pip install manim\n'
      'then open this page again.';

  static const latexHelp = 'Math needs LaTeX. In Terminal (asks for your password):\n'
      '  brew install --cask basictex\n'
      '  sudo /Library/TeX/texbin/tlmgr update --self\n'
      '  sudo /Library/TeX/texbin/tlmgr install standalone preview doublestroke relsize fundus-calligra '
      'wasysym physics dvisvgm rsfs wasy cm-super';

  /// Renders `scene` (class `className`) with `files` beside it (name → bytes) into the captures folder.
  /// Returns the saved file, or null after logging why. The temporary folder is removed either way.
  static Future<String?> render({
    required String manim,
    required String code,
    required String className,
    Map<String, List<int>> files = const {},
    required int width,
    required int height,
    int fps = 30,
    bool gif = false,
    String prefix = 'SnapNow Manim',
    required void Function(String) log,
    void Function(Process)? started,
  }) async {
    final dir = await Directory.systemTemp.createTemp('snapnow-manim-');
    try {
      await File('${dir.path}/scene.py').writeAsString(code);
      for (final e in files.entries) {
        await File('${dir.path}/${e.key}').writeAsBytes(e.value);
      }
      final args = ['-r', '$width,$height', '--fps', '$fps', '--format', gif ? 'gif' : 'mp4',
        '--media_dir', '${dir.path}/media', '-o', 'SnapNow', 'scene.py', className];
      log('\$ ${manim.split('/').last} ${args.join(' ')}\n');
      final p = await Process.start(manim, args, workingDirectory: dir.path, environment: env);
      started?.call(p);
      final done = Completer<void>();
      var open = 2;
      void closed() { if (--open == 0) done.complete(); }
      p.stdout.transform(utf8.decoder).listen(log, onDone: closed);
      p.stderr.transform(utf8.decoder).listen(log, onDone: closed);
      final exit = await p.exitCode;
      await done.future;
      if (exit != 0) {
        log('\nManim stopped with an error (exit code $exit). The message above says which line.\n');
        return null;
      }
      final ext = gif ? 'gif' : 'mp4';
      final made = Directory('${dir.path}/media').listSync(recursive: true)
          .whereType<File>().where((f) => f.path.endsWith('/SnapNow.$ext')).firstOrNull;
      if (made == null) {
        log('\nManim finished but no .$ext was written.\n');
        return null;
      }
      // A free name in the captures folder, so the Library shows it and nothing is overwritten
      final dest = AppController.newCapturePath(prefix: prefix, ext: ext);
      await made.copy(dest);
      AppController.instance.capturesVersion.value++;
      log('\nSaved to the Library: ${dest.split('/').last}\n');
      return dest;
    } catch (e) {
      log('\nCouldn\'t render: $e\n');
      return null;
    } finally {
      try { await dir.delete(recursive: true); } catch (_) {}
    }
  }
}
