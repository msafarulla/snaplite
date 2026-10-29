import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../app/app_controller.dart';
import '../export/manim_scene.dart';
import '../model/annotation.dart';
import '../platform/native.dart';

/// Animate with Manim: the capture as a Manim scene you can edit, rendered by the Manim installed on this
/// Mac into a GIF or MP4 that lands in the Library. SnapNow doesn't ship Manim; it finds it (see [_find]).
class ManimPage extends StatefulWidget {
  final CanvasState state;
  const ManimPage({super.key, required this.state});

  @override
  State<ManimPage> createState() => _ManimPageState();
}

class _ManimPageState extends State<ManimPage> {
  /// Where SnapNow looks for Manim, in order: its own install (README), then the usual places.
  static final _candidates = [
    '${Platform.environment['HOME']}/.local/share/snapnow/manim/bin/manim',
    '/opt/homebrew/bin/manim',
    '/usr/local/bin/manim',
    '${Platform.environment['HOME']}/.local/bin/manim',
  ];

  late final _code = TextEditingController(text: ManimScene.code(widget.state));
  final _log = StringBuffer();
  final _logScroll = ScrollController();
  String? _manim, _version;
  bool _looked = false, _rendering = false;
  bool _hd = false, _gif = true;
  String? _result;
  Process? _process;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void dispose() {
    _process?.kill();
    _code.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// The first Manim that runs, with its version (shown, so it's clear which program renders the code).
  Future<void> _find() async {
    for (final path in _candidates) {
      if (!File(path).existsSync()) continue;
      try {
        final r = await Process.run(path, ['--version'], environment: _env);
        final v = '${r.stdout}'.trim().split('\n').last.trim();
        if (r.exitCode == 0 && v.isNotEmpty) {
          setState(() { _manim = path; _version = v; });
          break;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _looked = true);
  }

  /// Homebrew first on PATH: a GUI app's PATH doesn't have it, and Manim may call ffmpeg.
  static Map<String, String> get _env =>
      {'PATH': '/opt/homebrew/bin:/usr/local/bin:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}'};

  void _say(String text) {
    setState(() => _log.write(text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _render() async {
    final manim = _manim;
    if (manim == null || _rendering) return;
    setState(() { _rendering = true; _result = null; _log.clear(); });
    final dir = await Directory.systemTemp.createTemp('snapnow-manim-');
    try {
      await File('${dir.path}/scene.py').writeAsString(_code.text);
      await File('${dir.path}/${ManimScene.backdropFile}').writeAsBytes(await ManimScene.backdrop(widget.state));
      final height = _hd ? 1080 : 480;
      final width = (height * ManimScene.aspect(widget.state) / 2).round() * 2;
      final args = ['-r', '$width,$height', '--fps', _hd ? '30' : '15', '--format', _gif ? 'gif' : 'mp4',
        '--media_dir', '${dir.path}/media', '-o', 'SnapNow', 'scene.py', ManimScene.className];
      _say('\$ ${manim.split('/').last} ${args.join(' ')}\n');
      final p = _process = await Process.start(manim, args, workingDirectory: dir.path, environment: _env);
      final done = Completer<void>();
      var open = 2;
      void closed() { if (--open == 0) done.complete(); }
      p.stdout.transform(utf8.decoder).listen(_say, onDone: closed);
      p.stderr.transform(utf8.decoder).listen(_say, onDone: closed);
      final code = await p.exitCode;
      await done.future;
      _process = null;
      if (code != 0) {
        _say('\nManim stopped with an error (exit code $code). The message above says which line.\n');
        return;
      }
      final ext = _gif ? 'gif' : 'mp4';
      final made = Directory('${dir.path}/media').listSync(recursive: true)
          .whereType<File>().where((f) => f.path.endsWith('/SnapNow.$ext')).firstOrNull;
      if (made == null) {
        _say('\nManim finished but no .$ext was written.\n');
        return;
      }
      // A free name in the captures folder, so the Library shows it (and nothing is overwritten)
      final dest = AppController.newCapturePath(prefix: 'SnapNow Manim', ext: ext);
      await made.copy(dest);
      AppController.instance.capturesVersion.value++;
      setState(() => _result = dest);
      _say('\nSaved to the Library: ${dest.split('/').last}\n');
    } catch (e) {
      _say('\nCouldn\'t render: $e\n');
    } finally {
      if (mounted) setState(() => _rendering = false);
      try { await dir.delete(recursive: true); } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = TextStyle(fontFamily: 'Menlo', fontSize: 12.5, height: 1.4, color: scheme.onSurface);
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('Animate with Manim', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        backgroundColor: scheme.surfaceContainerLow,
        actions: [
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('GIF')), ButtonSegment(value: false, label: Text('MP4'))],
            selected: {_gif},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _gif = v.first),
          ),
          const SizedBox(width: 8),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: false, label: Text('Preview')), ButtonSegment(value: true, label: Text('HD 1080p'))],
            selected: {_hd},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _hd = v.first),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _rendering ? null : () => setState(() => _code.text = ManimScene.code(widget.state)),
            child: const Text('Reset Code'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey('manim-render'),
            onPressed: _manim == null || _rendering ? null : _render,
            icon: _rendering
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(_rendering ? 'Rendering…' : 'Render'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _status(scheme),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              key: const ValueKey('manim-code'),
              controller: _code,
              maxLines: null,
              expands: true,
              style: mono,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                filled: true,
                fillColor: scheme.surfaceContainerLowest,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: scheme.outlineVariant)),
              ),
            ),
          ),
        ),
        Container(
          height: 150,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(8)),
          child: SingleChildScrollView(
            controller: _logScroll,
            child: SelectableText(_log.isEmpty ? 'Render output appears here.' : _log.toString(),
                style: mono.copyWith(color: const Color(0xFFD4D4D4), fontSize: 11.5)),
          ),
        ),
      ]),
    );
  }

  Widget _status(ColorScheme scheme) {
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    if (!_looked) return Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: Text('Looking for Manim…', style: small));
    if (_manim == null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(8)),
        child: SelectableText(
          'Manim isn\'t installed. In Terminal:\n'
          '  brew install cairo pango pkgconf ffmpeg\n'
          '  python3 -m venv ~/.local/share/snapnow/manim\n'
          '  ~/.local/share/snapnow/manim/bin/pip install manim\n'
          'then open this page again.',
          style: TextStyle(fontFamily: 'Menlo', fontSize: 12, color: scheme.onErrorContainer),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('$_version  ·  ${_manim!.replaceFirst(Platform.environment['HOME'] ?? '~', '~')}', style: small),
        Text('Render runs this Python code on your Mac.', style: small),
        if (_result != null) ...[
          TextButton(onPressed: () => Native.openPath(_result!), child: const Text('Open Result')),
          TextButton(onPressed: () => Native.reveal(_result!), child: const Text('Show in Finder')),
        ],
      ]),
    );
  }
}
