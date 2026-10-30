import 'dart:io';
import 'package:flutter/material.dart';
import '../export/manim_scene.dart';
import '../manim/manim_runner.dart';
import '../model/annotation.dart';
import '../platform/native.dart';

/// Animate with Manim: the capture as a Manim scene you can edit, rendered by the Manim installed on this
/// Mac into an MP4 (or GIF) that lands in the Library. SnapNow doesn't ship Manim ([ManimRunner]).
class ManimPage extends StatefulWidget {
  final CanvasState state;
  const ManimPage({super.key, required this.state});

  @override
  State<ManimPage> createState() => _ManimPageState();
}

class _ManimPageState extends State<ManimPage> {
  late final _code = TextEditingController(text: ManimScene.code(widget.state));
  final _log = StringBuffer();
  final _logScroll = ScrollController();
  String? _manim, _version;
  bool _looked = false, _rendering = false;
  bool _hd = false, _gif = false; // MP4 by default: Manim is made for video (a GIF is ~100x bigger)
  String? _result;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void dispose() {
    _code.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final m = await ManimRunner.find();
    if (!mounted) return;
    setState(() { _manim = m?.path; _version = m?.version; _looked = true; });
  }

  void _say(String text) {
    if (!mounted) return; // a render left running after the page closed still saves to the Library
    setState(() => _log.write(text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _render() async {
    final manim = _manim;
    if (manim == null || _rendering) return;
    setState(() { _rendering = true; _result = null; _log.clear(); });
    final height = _hd ? 1080 : 480;
    final result = await ManimRunner.render(
      manim: manim,
      code: _code.text,
      className: ManimScene.className,
      files: {ManimScene.backdropFile: await ManimScene.backdrop(widget.state)},
      width: (height * ManimScene.aspect(widget.state) / 2).round() * 2,
      height: height,
      fps: _hd ? 30 : 15,
      gif: _gif,
      log: _say,
    );
    if (mounted) setState(() { _rendering = false; _result = result; });
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
            segments: const [ButtonSegment(value: false, label: Text('MP4')), ButtonSegment(value: true, label: Text('GIF (large)'))],
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
          ManimRunner.installHelp,
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
