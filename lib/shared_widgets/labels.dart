import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'bauhaus_card.dart';
import 'focus_ring.dart';

/// The stencilled Bauhaus label: uppercase, 11px from `labelSmall`,
/// `letterSpacing: 0.12em`, w600. Eyebrows, stat labels, metadata.
///
/// The size comes from the [TextTheme], so it grows with the system text
/// scale — nothing here hard-codes a font size.
class EyebrowLabel extends StatelessWidget {
  const EyebrowLabel(
    this.text, {
    super.key,
    this.color,
    this.semanticsLabel,
    this.textAlign,
  });

  final String text;

  /// Defaults to `tokens.ink`. On a surface, `tokens.inkSecondary` is safe at
  /// this size; on the ice ground it is not — leave it alone there.
  final Color? color;

  /// Screen readers get the un-stencilled text. Defaults to [text] as written.
  final String? semanticsLabel;

  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return Text(
      text.toUpperCase(),
      textAlign: textAlign,
      semanticsLabel: semanticsLabel ?? text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color ?? t.ink,
      ),
    );
  }
}

/// A section rule: eyebrow, optional trailing action, and a hairline.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.trailing,
    this.rule = true,
  });

  final String title;
  final String? eyebrow;
  final Widget? trailing;

  /// Draw the hairline under the header.
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (eyebrow != null) ...[
                    EyebrowLabel(eyebrow!),
                    const SizedBox(height: 4),
                  ],
                  Semantics(
                    header: true,
                    child: Text(title, style: theme.textTheme.headlineMedium),
                  ),
                ],
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: trailing,
              ),
          ],
        ),
        if (rule) ...[
          const SizedBox(height: 8),
          Container(height: 2, color: t.line),
        ],
      ],
    );
  }
}

/// One number and its stencilled label, on a flat plane. The dashboard's
/// atomic unit.
///
/// When [numericValue] is given the figure counts up on first build (tabular
/// figures, live region) instead of appearing instantly.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    this.value,
    this.numericValue,
    this.valuePrefix = '',
    this.valueSuffix = '',
    this.caption,
    this.icon,
    this.accent,
    this.onTap,
    this.bordered = true,
    this.semanticLabel,
    this.liveRegion = false,
  });

  /// The stencilled eyebrow, e.g. `PARTICIPANTS`.
  final String label;

  /// Pre-formatted figure. Ignored when [numericValue] is set.
  final String? value;

  /// Counts up to this on first build.
  final int? numericValue;

  final String valuePrefix;
  final String valueSuffix;

  /// Small line under the figure — a delta, a denominator, a hint.
  final String? caption;

  final IconData? icon;

  /// Colour for the figure. Use the semantic *ink* tokens, never the fills.
  final Color? accent;

  final VoidCallback? onTap;

  /// Draw the plane. Off when the tile already sits inside a [BentoTile].
  final bool bordered;

  final String? semanticLabel;

  /// Set for figures that change live (scores, counts of joined players).
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final figureColor = accent ?? t.ink;
    final figureStyle = theme.textTheme.displaySmall?.copyWith(
      color: figureColor,
    );

    final Widget figure = numericValue != null
        ? CountUp(
            value: numericValue!,
            prefix: valuePrefix,
            suffix: valueSuffix,
            style: figureStyle,
            liveRegion: liveRegion,
            semanticsLabel: '$label: $valuePrefix$numericValue$valueSuffix',
          )
        : Text(
            '$valuePrefix${value ?? '—'}$valueSuffix',
            style: figureStyle,
          );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: t.ink),
              const SizedBox(width: 6),
            ],
            Expanded(child: EyebrowLabel(label)),
          ],
        ),
        const SizedBox(height: 10),
        figure,
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(
            caption!,
            style: theme.textTheme.bodySmall?.copyWith(
              // Secondary ink is only safe on a surface; inside a bordered
              // tile we are on one, otherwise stay on primary ink.
              color: bordered ? t.inkSecondary : t.ink,
            ),
          ),
        ],
      ],
    );

    if (!bordered) {
      return Semantics(
        label: semanticLabel,
        child: content,
      );
    }

    return BauhausCard(
      onTap: onTap,
      semanticLabel:
          semanticLabel ??
          (onTap == null
              ? null
              : '$label, $valuePrefix${numericValue ?? value ?? ''}$valueSuffix'),
      accentBar: accent,
      child: content,
    );
  }
}

/// A pill — one of the only two rounded things in the system (the other is the
/// join-code field). Chips and badges only.
class BauhausChip extends StatefulWidget {
  const BauhausChip({
    super.key,
    required this.label,
    this.fill,
    this.ink,
    this.borderColor,
    this.icon,
    this.dense = false,
    this.semanticLabel,
    this.onTap,
  });

  final String label;

  /// Defaults to `tokens.surface`.
  final Color? fill;

  /// Defaults to `tokens.ink`. Pass white when [fill] is a semantic colour.
  final Color? ink;

  final Color? borderColor;
  final IconData? icon;

  /// Tighter padding for inline use in a list row.
  final bool dense;

  final String? semanticLabel;
  final VoidCallback? onTap;

  @override
  State<BauhausChip> createState() => _BauhausChipState();
}

class _BauhausChipState extends State<BauhausChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final fg = widget.ink ?? t.ink;

    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.dense ? 10 : 12,
        vertical: widget.dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: widget.fill ?? t.surface,
        borderRadius: QuizzleTokens.pillRadius,
        border: Border.all(
          color: widget.borderColor ?? t.line,
          width: t.borderWidth,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 13, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              widget.label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );

    final labelled = Semantics(
      label: widget.semanticLabel ?? widget.label,
      excludeSemantics: true,
      button: widget.onTap != null,
      child: body,
    );

    if (widget.onTap == null) return labelled;

    return MergeSemantics(
      child: FocusRing(
        focused: _focused,
        radius: QuizzleTokens.pillRadius,
        child: Material(
          color: const Color(0x00000000),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onFocusChange: (v) => setState(() => _focused = v),
            focusColor: const Color(0x00000000),
            customBorder: const StadiumBorder(),
            // The pill stays visually tight; the hit area is padded out to the
            // 48px minimum.
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: t.minTouchTarget),
              child: Center(widthFactor: 1, child: labelled),
            ),
          ),
        ),
      ),
    );
  }
}
