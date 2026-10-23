import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../model/annotation.dart';
import 'canvas_painter.dart';
import 'quick_styles.dart';

/// What the panel reads from and does to the editor.
abstract class PanelHost {
  Annotation? get selected;
  Tool get tool;
  Color get color;
  StrokeSize get size;
  StyleKind? get styleKind;
  ArrowStyle get currentArrowStyle;
  bool get selectionIsCurved;
  void pickColor(Color c);
  void openColorPanel();
  void pickSize(StrokeSize s);
  void setArrowStyle(ArrowStyle s);
  void applyQuickStyle(QuickStyle q);
  void straighten();
  void resetStyle();
  void copyAllText();
  void saveCurrentStyle();
  void clearSavedStyles();
  void quickSetChanged();
}

/// The right-hand panel, as in the Swift app: Styles for the current kind, then its properties.
/// It edits the selected annotation when there is one, otherwise the defaults for the active tool.
class PropertiesPanel extends StatelessWidget {
  static const width = 248.0;
  static const colors = <(String, Color)>[
    ('Red', Color(0xFFFF3B30)), ('Orange', Color(0xFFFF9500)), ('Yellow', Color(0xFFFFCC00)), ('Green', Color(0xFF34C759)),
    ('Blue', Color(0xFF007AFF)), ('Purple', Color(0xFFAF52DE)), ('Black', Color(0xFF000000)), ('White', Color(0xFFFFFFFF)),
  ];

  final PanelHost host;
  const PropertiesPanel({super.key, required this.host});

  String get _title {
    final a = host.selected;
    if (a != null) {
      return switch (a.shape) {
        ArrowShape() => 'Arrow', LineShape() => 'Line', RectShape() => 'Box', EllipseShape() => 'Ellipse',
        PenShape() => 'Pen', HighlightShape() => 'Highlight', TextShape() => 'Text', CalloutShape() => 'Callout',
        StepShape() => 'Step', BlurShape() => 'Blur', SpotlightShape() => 'Spotlight', ImageShape() => 'Image',
      };
    }
    return '${_toolLabel(host.tool)} Tool';
  }

  static String _toolLabel(Tool t) => const {
        Tool.select: 'Select', Tool.arrow: 'Arrow', Tool.line: 'Line', Tool.box: 'Box', Tool.ellipse: 'Ellipse',
        Tool.pen: 'Pen', Tool.highlight: 'Highlight', Tool.text: 'Text', Tool.callout: 'Callout', Tool.step: 'Step',
        Tool.blur: 'Blur', Tool.spotlight: 'Spotlight', Tool.crop: 'Crop', Tool.grabText: 'Copy Text',
      }[t]!;

  QuickKind? get _kind {
    final a = host.selected;
    return a != null ? QuickKind.of(a) : QuickKind.ofTool(host.tool);
  }

  bool get _usesColor {
    final a = host.selected;
    if (a != null) return a.shape is! BlurShape && a.shape is! SpotlightShape && a.shape is! ImageShape;
    return !const {Tool.select, Tool.blur, Tool.spotlight, Tool.crop, Tool.grabText}.contains(host.tool);
  }

  String get _hint => switch (host.tool) {
        Tool.select => 'Click an annotation to edit it. Drag to move, drag handles to resize, Delete removes it.',
        Tool.blur => 'Drag over anything private to blur it.',
        Tool.spotlight => 'Drag around what matters; everything else is dimmed.',
        Tool.crop => 'Drag the area to keep.',
        Tool.grabText => 'Drag over text to copy it. Table columns become tabs, so grids paste into Excel.',
        _ => host.selected?.shape is ImageShape ? 'Drag to move, corners resize. Flatten All merges it into the image.' : '',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final kids = <Widget>[];
    final kind = _kind;

    if (kind != null) {
      kids.addAll([
        _heading(context, 'Styles'),
        _row(context, 'Theme', [
          _Dropdown<String>(
            width: 128,
            value: QuickStyles.currentSet,
            items: [for (final s in QuickStyles.sets) (s.$1, s.$1, null), (QuickStyles.mine, QuickStyles.mine, null)],
            onChanged: (v) async { await QuickStyles.setCurrent(v); host.quickSetChanged(); },
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: 'Save or clear your own styles',
            icon: const Icon(Icons.settings_outlined, size: 18),
            iconSize: 18,
            padding: EdgeInsets.zero,
            onSelected: (v) => v == 'save' ? host.saveCurrentStyle() : host.clearSavedStyles(),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'save', height: 32, child: Text('Save Current Style', style: TextStyle(fontSize: 13))),
              PopupMenuItem(value: 'clear', height: 32, child: Text('Clear My Styles for ${_title.replaceAll(' Tool', '')}', style: const TextStyle(fontSize: 13))),
            ],
          ),
        ]),
      ]);
      final presets = QuickStyles.presets(kind);
      kids.add(presets.isEmpty
          ? _note(context, 'No saved styles yet. Style an annotation, then ⚙ › Save Current Style.')
          : Wrap(spacing: 4, runSpacing: 4, children: [
              for (final q in presets) _QuickTile(q: q, kind: kind, onTap: () => host.applyQuickStyle(q)),
            ]));
      kids.add(_separator(context));
    }

    kids.add(_heading(context, _title));
    if (!_usesColor) {
      kids.add(_note(context, _hint));
      if (host.tool == Tool.grabText) {
        kids.add(Align(alignment: Alignment.centerLeft, child: _PillButton(icon: Icons.content_paste, label: 'Copy All Text', onTap: host.copyAllText)));
      }
    } else {
      kids.addAll([
        _heading(context, 'Color', small: true),
        Wrap(spacing: 4, runSpacing: 6, children: [
          for (final (name, c) in colors) _Swatch(color: c, name: name, selected: c.toARGB32() == host.color.toARGB32(), onTap: () => host.pickColor(c)),
          Tooltip(
            message: 'Any color',
            child: InkResponse(
              onTap: host.openColorPanel,
              radius: 14,
              child: Container(
                width: 20, height: 20,
                decoration: const BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [
                  Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red])),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        _row(context, 'Size', [
          _Segmented<StrokeSize>(
            values: StrokeSize.values,
            selected: host.size,
            label: (s) => s.label,
            tooltip: (s) => const ['Small', 'Medium', 'Large'][s.index],
            onTap: host.pickSize,
          ),
        ]),
      ]);

      final styleKind = host.styleKind;
      if (styleKind != null) {
        final style = host.currentArrowStyle;
        final isLine = styleKind != StyleKind.shape;
        if (isLine) {
          kids.addAll([
            _separator(context),
            _heading(context, 'Arrowheads', small: true),
            _row(context, 'Start', [_headMenu(style, start: true)]),
            _row(context, 'End', [_headMenu(style, start: false)]),
            _row(context, 'Head size', [
              _Dropdown<HeadSize>(
                value: style.headSize,
                items: [for (final h in HeadSize.values) (h, h.label, StylePreview(ArrowStyle(end: ArrowHead.triangle, headSize: h)))],
                onChanged: (h) => host.setArrowStyle(style.copyWith(headSize: h)),
              ),
            ]),
            _row(context, '', [
              _PillButton(icon: Icons.swap_horiz, label: 'Swap Ends',
                  onTap: () => host.setArrowStyle(style.copyWith(start: style.end, end: style.start))),
            ]),
          ]);
        }
        kids.addAll([
          _separator(context),
          _heading(context, 'Line', small: true),
          _row(context, 'Pattern', [
            _Dropdown<LinePattern>(
              value: style.pattern,
              items: [for (final p in LinePattern.values) (p, p.label, StylePreview(ArrowStyle(end: ArrowHead.none, pattern: p), line: isLine))],
              onChanged: (p) => host.setArrowStyle(style.copyWith(pattern: p)),
            ),
          ]),
          if (isLine) _check(context, 'Tapered', style.tapered, (v) => host.setArrowStyle(style.copyWith(tapered: v))),
          _check(context, 'Outline', style.outline, (v) => host.setArrowStyle(style.copyWith(outline: v))),
          _check(context, 'Shadow', style.shadow, (v) => host.setArrowStyle(style.copyWith(shadow: v))),
          const SizedBox(height: 4),
          if (isLine)
            _row(context, '', [
              Tooltip(
                message: 'Remove the curve (drag the round middle handle to bend)',
                child: _PillButton(icon: Icons.horizontal_rule, label: 'Straighten', onTap: host.selectionIsCurved ? host.straighten : null),
              ),
            ]),
          _row(context, '', [_PillButton(icon: Icons.restart_alt, label: 'Reset Style', onTap: host.resetStyle)]),
        ]);
      }
    }

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: t.colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final k in kids) Padding(padding: const EdgeInsets.only(bottom: 8), child: k),
        ]),
      ),
    );
  }

  Widget _headMenu(ArrowStyle style, {required bool start}) => _Dropdown<ArrowHead>(
        value: start ? style.start : style.end,
        items: [
          for (final h in ArrowHead.values)
            (h, h.label, StylePreview(start
                ? ArrowStyle(start: h, end: ArrowHead.none, headSize: style.headSize)
                : ArrowStyle(start: ArrowHead.none, end: h, headSize: style.headSize))),
        ],
        onChanged: (h) => host.setArrowStyle(start ? style.copyWith(start: h) : style.copyWith(end: h)),
      );

  static Widget _heading(BuildContext context, String text, {bool small = false}) {
    final s = Theme.of(context).colorScheme;
    return Text(small ? text.toUpperCase() : text,
        style: TextStyle(fontSize: small ? 10.5 : 13, fontWeight: FontWeight.w600, letterSpacing: small ? 0.6 : 0,
            color: small ? s.onSurfaceVariant : s.onSurface));
  }

  static Widget _note(BuildContext context, String text) =>
      Text(text, style: TextStyle(fontSize: 12, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant));

  static Widget _row(BuildContext context, String label, List<Widget> children) => Row(children: [
        SizedBox(width: 64, child: Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
        ...children,
      ]);

  static Widget _separator(BuildContext context) =>
      Divider(height: 8, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6));

  static Widget _check(BuildContext context, String label, bool value, ValueChanged<bool> onChanged) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!value),
        child: Row(children: [
          const SizedBox(width: 60),
          SizedBox(width: 22, height: 22, child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5)),
        ]),
      );
}

/// A compact popup menu showing a preview + label for each choice.
class _Dropdown<T> extends StatelessWidget {
  final T value;
  final List<(T, String, Widget?)> items;
  final ValueChanged<T> onChanged;
  final double width;
  const _Dropdown({required this.value, required this.items, required this.onChanged, this.width = 152});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final current = items.firstWhere((i) => i.$1 == value, orElse: () => items.first);
    Widget entry((T, String, Widget?) i) => Row(mainAxisSize: MainAxisSize.min, children: [
          if (i.$3 != null) ...[SizedBox(width: 48, height: 18, child: i.$3), const SizedBox(width: 8)],
          Flexible(child: Text(i.$2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
        ]);
    return PopupMenuButton<T>(
      tooltip: '',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [for (final i in items) PopupMenuItem<T>(value: i.$1, height: 30, child: entry(i))],
      child: Container(
        width: width,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: s.outlineVariant),
        ),
        child: Row(children: [
          Expanded(child: entry(current)),
          Icon(Icons.unfold_more, size: 14, color: s.onSurfaceVariant),
        ]),
      ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final String Function(T) tooltip;
  final ValueChanged<T> onTap;
  const _Segmented({required this.values, required this.selected, required this.label, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final v in values)
          Tooltip(
            message: tooltip(v),
            child: GestureDetector(
              onTap: () => onTap(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 42, height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: v == selected ? s.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: v == selected ? const [BoxShadow(color: Color(0x22000000), blurRadius: 2, offset: Offset(0, 1))] : null,
                ),
                child: Text(label(v), style: TextStyle(fontSize: 12, fontWeight: v == selected ? FontWeight.w600 : FontWeight.w400)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({required this.color, required this.name, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 20, height: 20,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: s.outlineVariant),
            boxShadow: selected ? [BoxShadow(color: s.primary, spreadRadius: 2.5), BoxShadow(color: s.surface, spreadRadius: 1)] : null,
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _PillButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

/// A Quick Style tile, drawn with the real renderer (arrows point down-left), as in the Swift app.
class _QuickTile extends StatefulWidget {
  final QuickStyle q;
  final QuickKind kind;
  final VoidCallback onTap;
  const _QuickTile({required this.q, required this.kind, required this.onTap});
  @override
  State<_QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<_QuickTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 50, height: 41,
          decoration: BoxDecoration(
            color: _hover ? Theme.of(context).colorScheme.surfaceContainerHighest : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: CustomPaint(painter: _TilePainter(widget.q, widget.kind)),
        ),
      ),
    );
  }
}

class _TilePainter extends CustomPainter {
  final QuickStyle q;
  final QuickKind kind;
  _TilePainter(this.q, this.kind);

  @override
  void paint(Canvas canvas, Size size) {
    const w = 90.0, h = 72.0;
    final k = math.min(size.width / w, size.height / h);
    canvas.translate((size.width - w * k) / 2, (size.height - h * k) / 2);
    canvas.scale(k);
    Annotation ann(Shape s) => Annotation(id: 0, shape: s, color: q.colorValue, size: q.size, arrowStyle: q.style);
    switch (kind) {
      case QuickKind.arrow || QuickKind.line:
        CanvasPainter.drawAnnotation(canvas, ann(const ArrowShape(Offset(w - 14, 12), Offset(16, h - 12))));
      case QuickKind.shape:
        CanvasPainter.drawAnnotation(canvas, ann(const RectShape(Rect.fromLTWH(14, 12, w - 28, h - 24))));
      case QuickKind.highlight:
        final bar = Paint()..color = const Color(0xFF8C8C8C);
        for (final (i, bw) in [w - 28, w - 40, w - 34].indexed) {
          canvas.drawRRect(RRect.fromRectXY(Rect.fromLTWH(14, 18 + i * 14.0, bw, 6), 3, 3), bar);
        }
        CanvasPainter.drawAnnotation(canvas, ann(const HighlightShape(Rect.fromLTWH(10, 28, w - 20, 18))));
      case QuickKind.step:
        CanvasPainter.drawAnnotation(canvas, ann(const StepShape(Offset(w / 2, h / 2))), number: 1);
      case QuickKind.text || QuickKind.callout:
        final fs = q.size.fontSize;
        final origin = Offset(w / 2 - fs * 0.62, h / 2 - fs * 0.62);
        CanvasPainter.drawAnnotation(canvas, ann(kind == QuickKind.text ? TextShape('Aa', origin) : CalloutShape('Aa', origin, tail: const Offset(14, h - 6))));
    }
  }

  @override
  bool shouldRepaint(covariant _TilePainter old) => old.q != q || old.kind != kind;
}
