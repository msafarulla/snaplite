import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A custom-pixels field for picking an output size the user controls: the build-up GIF's longest side, or
/// the Manim render height. The value is always real pixels; a typed value is clamped to [min]..[max].
class SizeChooser extends StatefulWidget {
  final int value;
  final int min, max;
  final String unit;
  final ValueChanged<int> onChanged;
  const SizeChooser({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1,
    this.max = 10000,
    this.unit = 'px',
  });

  @override
  State<SizeChooser> createState() => _SizeChooserState();
}

class _SizeChooserState extends State<SizeChooser> {
  late final TextEditingController _c = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(SizeChooser old) {
    super.didUpdateWidget(old);
    // Reflect a value changed elsewhere, without stomping on mid-edit text.
    if (widget.value != old.value && '${widget.value}' != _c.text) _c.text = '${widget.value}';
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _commit(String s) {
    final n = int.tryParse(s.trim());
    if (n == null) {
      _c.text = '${widget.value}'; // reject junk, restore the last good value
      return;
    }
    final v = n.clamp(widget.min, widget.max);
    _c.text = '$v';
    if (v != widget.value) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 86,
      child: TextField(
        controller: _c,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          isDense: true,
          suffixText: widget.unit,
          suffixStyle: const TextStyle(fontSize: 11),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: _commit,
        onTapOutside: (_) {
          if (_c.text != '${widget.value}') _commit(_c.text);
        },
      ),
    );
  }
}
