import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'bauhaus_card.dart';
import 'focus_ring.dart';

/// The four Bauhaus primitives, in canonical option order.
enum AnswerShape { triangle, diamond, circle, square }

/// Where an answer tile is in the question lifecycle.
enum AnswerTileStatus {
  /// Selectable.
  idle,

  /// This is the player's locked-in choice (block-print offset).
  locked,

  /// Reveal is in: this is the correct answer. Wipes to `--correct`.
  correct,

  /// Reveal is in: this was the player's pick and it was wrong. Cross-fades to
  /// `--wrong`.
  wrong,

  /// Reveal is in and this tile is neither — desaturates and steps back.
  dimmed,
}

/// One answer option: a flat colour plane carrying a geometric primitive, the
/// option letter and the answer text.
///
/// Accessibility, in full, because this is the screen that failed the audit:
/// * `Semantics(button: true, label: 'Option A, <text>')` — **the letter is
///   text**, never conveyed by colour or shape alone.
/// * Reveal outcomes are appended to the label and announced as a live region.
/// * 2px focus ring, 48px minimum height, press scale at `durInstant`.
/// * No fixed aspect ratio and no hard-coded font size, so the tile grows with
///   the system text scale instead of clipping the answer.
class AnswerTile extends StatefulWidget {
  const AnswerTile({
    super.key,
    required this.index,
    required this.text,
    this.onPressed,
    this.status = AnswerTileStatus.idle,
    this.count,
    this.showCount = false,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
  });

  /// 0-based option index. Drives the letter, the shape and the fill.
  final int index;

  final String text;

  /// Null (or `enabled: false`) makes the tile inert but still readable.
  final VoidCallback? onPressed;

  final AnswerTileStatus status;

  /// How many players chose this option — shown after the reveal.
  final int? count;

  final bool showCount;

  final bool enabled;

  final FocusNode? focusNode;
  final bool autofocus;

  /// `A`, `B`, `C`, … for [index].
  static String letterFor(int index) => String.fromCharCode(65 + (index % 26));

  static AnswerShape shapeFor(int index) =>
      AnswerShape.values[index % AnswerShape.values.length];

  static Color fillFor(BuildContext context, int index) {
    final fills = QuizzleTokens.of(context).answerFills;
    return fills[index % fills.length];
  }

  @override
  State<AnswerTile> createState() => _AnswerTileState();
}

class _AnswerTileState extends State<AnswerTile> {
  bool _pressed = false;
  bool _focused = false;

  bool get _interactive =>
      widget.enabled &&
      widget.onPressed != null &&
      (widget.status == AnswerTileStatus.idle ||
          widget.status == AnswerTileStatus.locked);

  String get _semanticLabel {
    final letter = AnswerTile.letterFor(widget.index);
    final base = 'Option $letter, ${widget.text}';
    final outcome = switch (widget.status) {
      AnswerTileStatus.locked => 'your answer, locked in',
      AnswerTileStatus.correct => 'correct answer',
      AnswerTileStatus.wrong => 'your answer, incorrect',
      _ => null,
    };
    final tally = widget.showCount && widget.count != null
        ? '${widget.count} ${widget.count == 1 ? 'player' : 'players'} chose this'
        : null;
    return [base, outcome, tally].whereType<String>().join('. ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final base = AnswerTile.fillFor(context, widget.index);
    final letter = AnswerTile.letterFor(widget.index);
    final shape = AnswerTile.shapeFor(widget.index);
    final onFill = t.onAnswer;

    final revealed =
        widget.status == AnswerTileStatus.correct ||
        widget.status == AnswerTileStatus.wrong ||
        widget.status == AnswerTileStatus.dimmed;

    // The plane's contents, identical in every state so the wipe reads as a
    // colour change rather than a re-layout.
    Widget contentFor(Color fill) => Container(
      constraints: BoxConstraints(minHeight: t.minTouchTarget + 16),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: t.line, width: t.borderWidth),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      // The tile's whole label is assembled once, on the Semantics node
      // below; the visuals (including the wipe's second copy of the content)
      // must not announce themselves again.
      child: ExcludeSemantics(
        child: Row(
          children: [
            _ShapeGlyph(shape: shape, color: onFill, size: 22),
            const SizedBox(width: 12),
            // The letter, as text. This is the a11y contract.
            Text(
              letter,
              style: theme.textTheme.titleMedium?.copyWith(
                color: onFill,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.text,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: onFill,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (widget.status == AnswerTileStatus.correct) ...[
              const SizedBox(width: 8),
              Icon(Icons.check, color: onFill, size: 22),
            ] else if (widget.status == AnswerTileStatus.wrong) ...[
              const SizedBox(width: 8),
              Icon(Icons.close, color: onFill, size: 22),
            ],
            if (widget.showCount && widget.count != null) ...[
              const SizedBox(width: 10),
              Text(
                '${widget.count}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: onFill,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    // Correct wipes from the left; wrong cross-fades; everything else is flat.
    Widget plane;
    switch (widget.status) {
      case AnswerTileStatus.correct:
        plane = WipeReveal(
          revealed: true,
          duration: durSlow,
          overlay: contentFor(t.correct),
          child: contentFor(base),
        );
      case AnswerTileStatus.wrong:
        plane = _CrossFadeFill(from: base, to: t.wrong, builder: contentFor);
      case AnswerTileStatus.idle:
      case AnswerTileStatus.locked:
      case AnswerTileStatus.dimmed:
        plane = contentFor(base);
    }

    // The unchosen tiles desaturate once the answer is out.
    if (widget.status == AnswerTileStatus.dimmed) {
      plane = _Desaturate(amount: 1, child: plane);
    }

    if (_interactive) {
      plane = Material(
        color: const Color(0x00000000),
        child: InkWell(
          onTap: widget.onPressed,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onFocusChange: (v) => setState(() => _focused = v),
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
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

    // Lock-in: the 4px navy block-print offset. Space is always reserved so
    // locking in never reflows the grid.
    plane = BlockShadow(
      enabled: widget.status == AnswerTileStatus.locked,
      color: t.line,
      offset: t.blockShadowOffset,
      child: plane,
    );

    plane = FocusRing(focused: _focused, child: plane);

    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _interactive,
        selected:
            widget.status == AnswerTileStatus.locked ||
            widget.status == AnswerTileStatus.wrong,
        // The reveal outcome must reach a screen reader the moment it lands.
        liveRegion: revealed,
        label: _semanticLabel,
        // Not ExcludeSemantics: the InkWell's tap action has to survive so a
        // screen reader can activate the tile.
        child: plane,
      ),
    );
  }
}

/// Cross-fades the tile fill from [from] to [to] over `durSlow` — the wrong
/// pick's reveal.
class _CrossFadeFill extends StatelessWidget {
  const _CrossFadeFill({
    required this.from,
    required this.to,
    required this.builder,
  });

  final Color from;
  final Color to;
  final Widget Function(Color fill) builder;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return builder(to);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: from, end: to),
      duration: durSlow,
      curve: easeSnap,
      builder: (context, color, _) => builder(color ?? to),
    );
  }
}

/// Animated desaturation for the tiles nobody is looking at after the reveal.
class _Desaturate extends StatelessWidget {
  const _Desaturate({required this.amount, required this.child});

  /// 0 = untouched, 1 = fully grey.
  final double amount;

  final Widget child;

  static List<double> matrix(double saturation) {
    const lumR = 0.2126;
    const lumG = 0.7152;
    const lumB = 0.0722;
    final s = saturation.clamp(0.0, 1.0);
    final inv = 1 - s;
    return <double>[
      lumR * inv + s, lumG * inv, lumB * inv, 0, 0, //
      lumR * inv, lumG * inv + s, lumB * inv, 0, 0, //
      lumR * inv, lumG * inv, lumB * inv + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  @override
  Widget build(BuildContext context) {
    Widget filtered(double a) => ColorFiltered(
      colorFilter: ColorFilter.matrix(matrix(1 - a.clamp(0.0, 1.0))),
      child: child,
    );
    if (Motion.reduced(context)) return filtered(amount);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: amount),
      duration: durSlow,
      curve: easeSnap,
      builder: (context, a, _) => filtered(a),
    );
  }
}

/// The four primitives, drawn as geometry rather than icon-font glyphs so they
/// stay crisp and unmistakable at any size.
class _ShapeGlyph extends StatelessWidget {
  const _ShapeGlyph({required this.shape, required this.color, this.size = 22});

  final AnswerShape shape;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: AnswerShapePainter(shape, color)),
    );
  }
}

/// Paints one of the four answer primitives filled with [color].
class AnswerShapePainter extends CustomPainter {
  const AnswerShapePainter(this.shape, this.color);

  final AnswerShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;

    switch (shape) {
      case AnswerShape.triangle:
        canvas.drawPath(
          Path()
            ..moveTo(w / 2, 0)
            ..lineTo(w, h)
            ..lineTo(0, h)
            ..close(),
          paint,
        );
      case AnswerShape.diamond:
        canvas.drawPath(
          Path()
            ..moveTo(w / 2, 0)
            ..lineTo(w, h / 2)
            ..lineTo(w / 2, h)
            ..lineTo(0, h / 2)
            ..close(),
          paint,
        );
      case AnswerShape.circle:
        canvas.drawCircle(Offset(w / 2, h / 2), w / 2, paint);
      case AnswerShape.square:
        canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);
    }
  }

  @override
  bool shouldRepaint(AnswerShapePainter old) =>
      old.shape != shape || old.color != color;
}

/// A responsive, staggered grid of [AnswerTile]s — one column compact, two
/// wider. Tiles size to their content, so nothing clips at large text.
///
/// This is the shared presentation for the host projector and the student
/// device. Pass [selectedIndex] while the question is open and [correctIndex]
/// once the reveal lands; the per-tile [AnswerTileStatus] is derived from them.
class AnswerTileGrid extends StatelessWidget {
  const AnswerTileGrid({
    super.key,
    required this.options,
    this.onSelect,
    this.selectedIndex,
    this.correctIndex,
    this.counts,
    this.enabled = true,
    this.showCounts = false,
    this.stagger = true,
    this.columns,
    this.spacing = 12,
  });

  final List<String> options;

  /// Null makes the grid read-only (the host's view).
  final ValueChanged<int>? onSelect;

  final int? selectedIndex;

  /// Non-null means the reveal has happened.
  final int? correctIndex;

  final List<int>? counts;
  final bool enabled;
  final bool showCounts;
  final bool stagger;

  /// Overrides the responsive column count.
  final int? columns;

  final double spacing;

  AnswerTileStatus _statusFor(int i) {
    if (correctIndex == null) {
      return selectedIndex == i
          ? AnswerTileStatus.locked
          : AnswerTileStatus.idle;
    }
    if (correctIndex == i) return AnswerTileStatus.correct;
    if (selectedIndex == i) return AnswerTileStatus.wrong;
    return AnswerTileStatus.dimmed;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = columns ?? (width < 600 ? 1 : 2);

    final tiles = <Widget>[
      for (var i = 0; i < options.length; i++)
        AnswerTile(
          index: i,
          text: options[i],
          status: _statusFor(i),
          count: counts != null && i < counts!.length ? counts![i] : null,
          showCount: showCounts,
          enabled: enabled && correctIndex == null,
          onPressed: onSelect == null ? null : () => onSelect!(i),
        ),
    ];

    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += cols) {
      final slice = tiles.sublist(i, (i + cols).clamp(0, tiles.length));
      final cells = <Widget>[];
      for (var j = 0; j < cols; j++) {
        if (j > 0) cells.add(SizedBox(width: spacing));
        cells.add(
          Expanded(
            child: j < slice.length
                ? (stagger
                      ? StaggeredEntry(index: i + j, child: slice[j])
                      : slice[j])
                : const SizedBox(),
          ),
        );
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
      if (i + cols < tiles.length) rows.add(SizedBox(height: spacing));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}
