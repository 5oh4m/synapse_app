import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'focus_ring.dart';
import 'labels.dart';

/// A flat plane: solid fill, 2px ink border, hard corners, **no blur shadow**.
/// Elevation in this system is a line and an offset, never a glow.
///
/// Sizes to its content. Give it an [onTap] and it becomes a real button with a
/// focus ring, a press scale and a semantic label.
class BauhausCard extends StatefulWidget {
  const BauhausCard({
    super.key,
    required this.child,
    this.padding,
    this.background,
    this.borderColor,
    this.onTap,
    this.semanticLabel,
    this.blockShadow = false,
    this.accentBar,
    this.width,
    this.margin,
  });

  final Widget child;

  /// Defaults to 16px all round (the compact gutter).
  final EdgeInsetsGeometry? padding;

  /// Defaults to `tokens.surface`.
  final Color? background;

  /// Defaults to `tokens.line`.
  final Color? borderColor;

  /// Makes the whole plane tappable.
  final VoidCallback? onTap;

  /// Required-in-practice when [onTap] is set: what the card announces.
  final String? semanticLabel;

  /// Adds the 4px block-print offset behind the plane. Space is reserved
  /// whether or not it is drawn.
  final bool blockShadow;

  /// A 6px colour bar down the leading edge — the "one accent per screen"
  /// Bauhaus move. Use sparingly.
  final Color? accentBar;

  final double? width;
  final EdgeInsetsGeometry? margin;

  @override
  State<BauhausCard> createState() => _BauhausCardState();
}

class _BauhausCardState extends State<BauhausCard> {
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final interactive = widget.onTap != null;

    final body = Padding(
      padding: widget.padding ?? const EdgeInsets.all(16),
      child: widget.child,
    );

    Widget plane = Container(
      width: widget.width,
      decoration: t.plane(
        fill: widget.background ?? t.surface,
        borderColor: widget.borderColor ?? t.line,
      ),
      // IntrinsicHeight keeps the accent bar the height of the content: a
      // stretched Row alone would make the card swallow all available height.
      child: widget.accentBar == null
          ? body
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 6,
                    child: ColoredBox(color: widget.accentBar!),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
    );

    if (interactive) {
      plane = Material(
        color: const Color(0x00000000),
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onFocusChange: (v) => setState(() => _focused = v),
          focusColor: const Color(0x00000000),
          borderRadius: QuizzleTokens.radius,
          child: plane,
        ),
      );
      plane = AnimatedScale(
        scale: _pressed ? t.pressScale : 1.0,
        duration: Motion.dur(context, durInstant),
        curve: easeSnap,
        child: plane,
      );
    }

    Widget result = BlockShadow(
      enabled: widget.blockShadow,
      color: t.line,
      offset: t.blockShadowOffset,
      child: plane,
    );

    if (interactive) {
      result = FocusRing(focused: _focused, child: result);
      result = MergeSemantics(
        child: Semantics(
          button: true,
          label: widget.semanticLabel,
          child: result,
        ),
      );
    }

    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }
    return result;
  }
}

/// Draws (or reserves) the 4px block-print offset behind [child]. Bauhaus
/// elevation: a hard offset plane, no blur. The space is always reserved so
/// toggling [enabled] cannot shift layout.
class BlockShadow extends StatelessWidget {
  const BlockShadow({
    super.key,
    required this.child,
    required this.enabled,
    this.color,
    this.offset = const Offset(4, 4),
  });

  final Widget child;
  final bool enabled;
  final Color? color;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(right: offset.dx, bottom: offset.dy),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: offset.dx,
            top: offset.dy,
            right: -offset.dx,
            bottom: -offset.dy,
            child: AnimatedOpacity(
              opacity: enabled ? 1 : 0,
              duration: Motion.dur(context, durQuick),
              curve: easeSnap,
              child: ColoredBox(color: color ?? t.line),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// A bento module: a flat plane on the dashboard grid with an optional
/// eyebrow, title and trailing affordance. Sizes to content — no tile is
/// stretched over dead space, and nothing here fixes an aspect ratio, so text
/// at 200% scale grows the tile instead of clipping.
///
/// Place these in a [BentoGrid], which honours [columnSpan].
class BentoTile extends StatelessWidget {
  const BentoTile({
    super.key,
    required this.child,
    this.eyebrow,
    this.title,
    this.trailing,
    this.columnSpan = 1,
    this.padding,
    this.onTap,
    this.semanticLabel,
    this.background,
    this.accentBar,
  });

  final Widget child;

  /// The stencilled uppercase label above the title.
  final String? eyebrow;

  final String? title;

  /// Usually a [BauhausIconButton]; excluded from the tile's merged label.
  final Widget? trailing;

  /// How many grid columns this tile occupies. One tile per screen may span 2.
  final int columnSpan;

  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final Color? background;
  final Color? accentBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = eyebrow != null || title != null || trailing != null;

    return BauhausCard(
      onTap: onTap,
      semanticLabel: semanticLabel ?? title,
      background: background,
      accentBar: accentBar,
      padding: padding ?? const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasHeader)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (eyebrow != null) EyebrowLabel(eyebrow!),
                      if (eyebrow != null && title != null)
                        const SizedBox(height: 6),
                      if (title != null)
                        Text(title!, style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: trailing,
                  ),
              ],
            ),
          if (hasHeader) const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Unequal modular tiles on a fixed column grid.
///
/// Columns default to the form factor (1 compact / 2 medium / 3 expanded) and
/// the gutter to 16px compact / 24px wider, per DESIGN.md. Rows are packed
/// greedily, honouring each [BentoTile.columnSpan]; every row sizes to its
/// tallest tile via [IntrinsicHeight], so tiles stretch to their row but never
/// over dead space below it.
class BentoGrid extends StatelessWidget {
  const BentoGrid({
    super.key,
    required this.children,
    this.columns,
    this.gutter,
    this.stagger = true,
  });

  /// Tiles. [BentoTile]s have their span honoured; anything else spans 1.
  final List<Widget> children;

  final int? columns;
  final double? gutter;

  /// Play the 40ms staggered entry on first build.
  final bool stagger;

  int _spanOf(Widget w) => w is BentoTile ? w.columnSpan.clamp(1, 4) : 1;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final cols =
        columns ??
        (width < 600
            ? 1
            : width < 1024
            ? 2
            : 3);
    final gap = gutter ?? t.gutterFor(width);

    // Pack into rows.
    final rows = <List<Widget>>[];
    var current = <Widget>[];
    var used = 0;
    for (final child in children) {
      final span = _spanOf(child).clamp(1, cols);
      if (used + span > cols && current.isNotEmpty) {
        rows.add(current);
        current = <Widget>[];
        used = 0;
      }
      current.add(child);
      used += span;
    }
    if (current.isNotEmpty) rows.add(current);

    var flatIndex = 0;
    final rowWidgets = <Widget>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      final cells = <Widget>[];
      for (var i = 0; i < row.length; i++) {
        final span = _spanOf(row[i]).clamp(1, cols);
        Widget cell = row[i];
        if (stagger) {
          cell = StaggeredEntry(index: flatIndex, child: cell);
        }
        flatIndex++;
        cells.add(Expanded(flex: span, child: cell));
        if (i != row.length - 1) cells.add(SizedBox(width: gap));
      }
      // Fill the tail so a short row's tiles keep the column rhythm.
      final rowSpan = row.fold<int>(
        0,
        (sum, w) => sum + _spanOf(w).clamp(1, cols),
      );
      if (rowSpan < cols) {
        cells.add(SizedBox(width: gap));
        cells.add(Expanded(flex: cols - rowSpan, child: const SizedBox()));
      }
      rowWidgets.add(
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
        ),
      );
      if (r != rows.length - 1) rowWidgets.add(SizedBox(height: gap));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rowWidgets,
    );
  }
}
