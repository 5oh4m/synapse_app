import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'focus_ring.dart';

/// The four button roles in the system.
enum BauhausButtonVariant {
  /// Filled inverse plane — the one action a screen is about.
  primary,

  /// Surface plane with a 2px ink border.
  secondary,

  /// No plane, no border. Tertiary actions and dialog dismissals.
  ghost,

  /// Filled `--wrong` plane. Destructive only.
  danger,
}

/// A Bauhaus button: flat plane, hard corners, 2px border, mechanical press.
///
/// * `borderRadius: 0`, 2px border, no blur shadow.
/// * Press snaps to `pressScale` (0.97) at `durInstant`.
/// * 2px focus ring at a 2px offset, space always reserved.
/// * Minimum 48x48 hit area.
/// * Label text comes from the [TextTheme]; nothing here hard-codes a size, so
///   the button grows with the system text scale.
/// * Always reports `Semantics(button: true, label: …)`.
class BauhausButton extends StatefulWidget {
  const BauhausButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = BauhausButtonVariant.primary,
    this.icon,
    this.trailingIcon,
    this.semanticLabel,
    this.tooltip,
    this.expand = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  });

  /// Primary: the filled inverse plane.
  const BauhausButton.primary({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.trailingIcon,
    this.semanticLabel,
    this.tooltip,
    this.expand = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  }) : variant = BauhausButtonVariant.primary;

  /// Secondary: surface plane, ink border.
  const BauhausButton.secondary({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.trailingIcon,
    this.semanticLabel,
    this.tooltip,
    this.expand = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  }) : variant = BauhausButtonVariant.secondary;

  /// Ghost: type only.
  const BauhausButton.ghost({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.trailingIcon,
    this.semanticLabel,
    this.tooltip,
    this.expand = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  }) : variant = BauhausButtonVariant.ghost;

  /// Danger: the `--wrong` plane.
  const BauhausButton.danger({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.trailingIcon,
    this.semanticLabel,
    this.tooltip,
    this.expand = false,
    this.busy = false,
    this.focusNode,
    this.autofocus = false,
  }) : variant = BauhausButtonVariant.danger;

  final String label;

  /// Null disables the button (and reports `enabled: false` to semantics).
  final VoidCallback? onPressed;

  final BauhausButtonVariant variant;
  final IconData? icon;
  final IconData? trailingIcon;

  /// Overrides the announced label. The visible text is excluded from the
  /// semantics tree when this is set, so nothing is announced twice.
  final String? semanticLabel;

  final String? tooltip;

  /// Stretch to the parent's width.
  final bool expand;

  /// Shows a working indicator and blocks taps.
  final bool busy;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<BauhausButton> createState() => _BauhausButtonState();
}

class _BauhausButtonState extends State<BauhausButton> {
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final theme = Theme.of(context);

    late final Color background;
    late final Color foreground;
    late final Color borderColor;
    switch (widget.variant) {
      case BauhausButtonVariant.primary:
        background = _enabled ? t.inverseGround : t.inkMuted;
        foreground = _enabled ? t.inverseInk : t.ink;
        borderColor = t.line;
      case BauhausButtonVariant.secondary:
        background = t.surface;
        foreground = _enabled ? t.ink : t.inkSecondary;
        borderColor = _enabled ? t.line : t.lineMuted;
      case BauhausButtonVariant.ghost:
        background = const Color(0x00000000);
        foreground = _enabled ? t.ink : t.inkSecondary;
        borderColor = const Color(0x00000000);
      case BauhausButtonVariant.danger:
        background = _enabled ? t.wrong : t.inkMuted;
        foreground = _enabled ? t.onAnswer : t.ink;
        borderColor = t.line;
    }

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.busy)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _BusyBlocks(color: foreground),
          )
        else if (widget.icon != null)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Icon(widget.icon, size: 20, color: foreground),
          ),
        Flexible(
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            // From the TextTheme — scales with the system setting.
            style: theme.textTheme.labelLarge?.copyWith(color: foreground),
          ),
        ),
        if (widget.trailingIcon != null)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Icon(widget.trailingIcon, size: 20, color: foreground),
          ),
      ],
    );

    Widget button = Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: QuizzleTokens.radius,
        side: BorderSide(color: borderColor, width: t.borderWidth),
      ),
      clipBehavior: Clip.none,
      child: InkWell(
        onTap: _enabled ? widget.onPressed : null,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onFocusChange: (v) => setState(() => _focused = v),
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        focusColor: const Color(0x00000000),
        borderRadius: QuizzleTokens.radius,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: t.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            // The visible text is announced by the outer Semantics node.
            child: Center(
              widthFactor: widget.expand ? null : 1,
              child: ExcludeSemantics(child: content),
            ),
          ),
        ),
      ),
    );

    button = AnimatedScale(
      scale: _pressed ? t.pressScale : 1.0,
      duration: Motion.dur(context, durInstant),
      curve: easeSnap,
      child: button,
    );

    button = FocusRing(focused: _focused, child: button);

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }

    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _enabled,
        label: widget.semanticLabel ?? widget.label,
        child: button,
      ),
    );
  }
}

/// Icon-only control. A tooltip is **required**, and it doubles as the
/// semantic label unless [semanticLabel] overrides it — the audit that failed
/// before found icon buttons with neither.
class BauhausIconButton extends StatefulWidget {
  const BauhausIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.semanticLabel,
    this.selected = false,
    this.bordered = true,
    this.iconSize = 22,
    this.color,
    this.focusNode,
    this.autofocus = false,
  });

  final IconData icon;

  /// Shown on hover/long-press and announced when [semanticLabel] is null.
  final String tooltip;

  final VoidCallback? onPressed;
  final String? semanticLabel;

  /// Draws the button as the inverse plane (a toggle in its on state).
  final bool selected;

  /// Draw the 2px plane border. Off for chrome that sits inside an app bar.
  final bool bordered;

  final double iconSize;
  final Color? color;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<BauhausIconButton> createState() => _BauhausIconButtonState();
}

class _BauhausIconButtonState extends State<BauhausIconButton> {
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final fg = widget.selected
        ? t.inverseInk
        : (widget.color ?? (_enabled ? t.ink : t.inkMuted));
    final bg = widget.selected ? t.inverseGround : const Color(0x00000000);
    final borderColor = widget.bordered
        ? (_enabled ? t.line : t.lineMuted)
        : const Color(0x00000000);

    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _enabled,
        toggled: widget.selected,
        label: widget.semanticLabel ?? widget.tooltip,
        child: Tooltip(
          message: widget.tooltip,
          child: FocusRing(
            focused: _focused,
            child: AnimatedScale(
              scale: _pressed ? t.pressScale : 1.0,
              duration: Motion.dur(context, durInstant),
              curve: easeSnap,
              child: Material(
                color: bg,
                shape: RoundedRectangleBorder(
                  borderRadius: QuizzleTokens.radius,
                  side: BorderSide(color: borderColor, width: t.borderWidth),
                ),
                child: InkWell(
                  onTap: widget.onPressed,
                  onTapDown: _enabled
                      ? (_) => setState(() => _pressed = true)
                      : null,
                  onTapUp: _enabled
                      ? (_) => setState(() => _pressed = false)
                      : null,
                  onTapCancel: _enabled
                      ? () => setState(() => _pressed = false)
                      : null,
                  onFocusChange: (v) => setState(() => _focused = v),
                  focusNode: widget.focusNode,
                  autofocus: widget.autofocus,
                  focusColor: const Color(0x00000000),
                  borderRadius: QuizzleTokens.radius,
                  child: SizedBox(
                    // 48x48 minimum, always.
                    width: t.minTouchTarget,
                    height: t.minTouchTarget,
                    child: Center(
                      child: ExcludeSemantics(
                        child: Icon(
                          widget.icon,
                          size: widget.iconSize,
                          color: fg,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three marching squares — the system's working indicator. Holds still under
/// reduced motion rather than spinning forever.
class _BusyBlocks extends StatefulWidget {
  const _BusyBlocks({required this.color});

  final Color color;

  static const double size = 5;

  @override
  State<_BusyBlocks> createState() => _BusyBlocksState();
}

class _BusyBlocksState extends State<_BusyBlocks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = List<Widget>.generate(3, (i) {
      return Padding(
        padding: EdgeInsets.only(right: i == 2 ? 0 : 3),
        child: SizedBox(
          width: _BusyBlocks.size,
          height: _BusyBlocks.size,
          child: ColoredBox(color: widget.color),
        ),
      );
    });

    if (Motion.reduced(context)) {
      return Row(mainAxisSize: MainAxisSize.min, children: blocks);
    }

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Opacity(
                opacity: 0.3 + 0.7 * _phase(i),
                child: blocks[i],
              ),
          ],
        );
      },
    );
  }

  double _phase(int i) {
    final v = (_c.value * 3 - i) % 3;
    return v < 1 ? 1 - v : 0;
  }
}
