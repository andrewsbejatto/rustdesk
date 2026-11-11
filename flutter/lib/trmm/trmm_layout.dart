// Layout helpers of the TRMM screens: resizable panes (size remembered per
// computer) and buttons that become icon-only on small screens.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Two panes with a draggable divider. [initial] is the fraction of the first
/// pane; the user's size is saved in the local option [storageKey].
/// Double click on the divider restores [initial].
class TrmmSplit extends StatefulWidget {
  final Axis axis;
  final Widget first;
  final Widget second;
  final double initial;
  final double minFirst;
  final double minSecond;
  final String storageKey;

  const TrmmSplit({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    required this.initial,
    required this.storageKey,
    this.minFirst = 120,
    this.minSecond = 160,
  });

  @override
  State<TrmmSplit> createState() => _TrmmSplitState();
}

class _TrmmSplitState extends State<TrmmSplit> {
  static const _handle = 6.0;
  late double _fraction = _load();

  double _load() {
    final v = double.tryParse(bind.mainGetLocalOption(key: widget.storageKey));
    return (v != null && v > 0 && v < 1) ? v : widget.initial;
  }

  void _save() => bind.mainSetLocalOption(key: widget.storageKey, value: _fraction.toStringAsFixed(4));

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    return LayoutBuilder(builder: (context, c) {
      final total = (horizontal ? c.maxWidth : c.maxHeight) - _handle;
      // small screens: keep both panes usable
      final minA = math.min(widget.minFirst, total * 0.4);
      final minB = math.min(widget.minSecond, total * 0.4);
      final first = (_fraction * total).clamp(minA, math.max(minA, total - minB)).toDouble();
      final divider = MouseRegion(
        cursor: horizontal ? SystemMouseCursors.resizeLeftRight : SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => setState(() {
            final pos = first + (horizontal ? d.delta.dx : d.delta.dy);
            _fraction = (pos / total).clamp(0.05, 0.95);
          }),
          onPanEnd: (_) => _save(),
          onDoubleTap: () {
            setState(() => _fraction = widget.initial);
            _save();
          },
          child: SizedBox(
            width: horizontal ? _handle : double.infinity,
            height: horizontal ? double.infinity : _handle,
            child: Center(
              child: horizontal
                  ? const VerticalDivider(width: 1, thickness: 1)
                  : const Divider(height: 1, thickness: 1),
            ),
          ),
        ),
      );
      final a = SizedBox(width: horizontal ? first : null, height: horizontal ? null : first, child: widget.first);
      return horizontal
          ? Row(children: [a, divider, Expanded(child: widget.second)])
          : Column(children: [a, divider, Expanded(child: widget.second)]);
    });
  }
}

/// TextButton with icon, or only the icon (label as tooltip) when [compact]
Widget trmmButton({
  required IconData icon,
  required String label,
  required VoidCallback? onPressed,
  bool compact = false,
  bool filled = false,
}) {
  if (compact) {
    return IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon, size: 20));
  }
  return filled
      ? FilledButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label))
      : TextButton.icon(onPressed: onPressed, icon: Icon(icon, size: 20), label: Text(label));
}

/// size of a big dialog limited to the screen
Size trmmDialogSize(BuildContext context, double width, double height) {
  final s = MediaQuery.of(context).size;
  return Size(math.min(width, s.width - 48), math.min(height, s.height - 48));
}

/// Single choice as radio buttons (same look as the web panel): the selected
/// option is always clear, chips/segments without a mark were confusing.
class TrmmRadioGroup<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final double spacing;

  const TrmmRadioGroup(
      {super.key, required this.options, required this.value, required this.onChanged, this.spacing = 12});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: spacing,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (v, label) in options)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onChanged == null ? null : () => onChanged!(v),
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Radio<T>(
                    value: v,
                    groupValue: value,
                    onChanged: onChanged == null ? null : (x) => onChanged!(x as T),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Text(label),
                ]),
              ),
            ),
        ],
      );
}

/// SegmentedButton style with the selected segment filled (the default of
/// the Material 2 theme barely marks it)
ButtonStyle trmmSegmentedStyle(BuildContext context, {bool compact = false}) {
  final cs = Theme.of(context).colorScheme;
  return ButtonStyle(
    visualDensity: compact ? VisualDensity.compact : null,
    backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? cs.primary : null),
    foregroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? cs.onPrimary : null),
  );
}
