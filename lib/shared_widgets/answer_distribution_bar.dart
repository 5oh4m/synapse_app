import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'answer_tile.dart';
import 'labels.dart';

/// The reveal's horizontal bar chart: one bar per option, each growing from
/// zero, staggered 40ms apart.
///
/// Every row states its option letter, its count and its share as text, so the
/// distribution is readable without seeing the colours. The whole chart is one
/// semantic region with a summary label.
class AnswerDistributionBar extends StatelessWidget {
  const AnswerDistributionBar({
    super.key,
    required this.counts,
    this.labels,
    this.correctIndex,
    this.animate = true,
    this.showPercent = true,
    this.barHeight = 18,
  });

  /// Responses per option, in option order.
  final List<int> counts;

  /// Option text, if you want it beside the letter. Truncated to one line.
  final List<String>? labels;

  /// Marks the correct row with the `--correct` fill and a check.
  final int? correctIndex;

  final bool animate;
  final bool showPercent;

  /// Track thickness. The row's text sizes independently from the [TextTheme].
  final double barHeight;

  int get _total => counts.fold<int>(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final total = _total;
    final max = counts.isEmpty ? 0 : counts.reduce((a, b) => a > b ? a : b);

    final summary = counts.isEmpty
        ? 'No responses yet'
        : [
            'Answer distribution.',
            for (var i = 0; i < counts.length; i++)
              'Option ${AnswerTile.letterFor(i)}: ${counts[i]} '
                  '${counts[i] == 1 ? 'response' : 'responses'}'
                  '${correctIndex == i ? ', correct answer' : ''}.',
          ].join(' ');

    return Semantics(
      label: summary,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < counts.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _Row(
              letter: AnswerTile.letterFor(i),
              label: labels != null && i < labels!.length ? labels![i] : null,
              count: counts[i],
              total: total,
              factor: max == 0 ? 0 : counts[i] / max,
              fill: correctIndex == i
                  ? t.correct
                  : AnswerTile.fillFor(context, i),
              isCorrect: correctIndex == i,
              animate: animate,
              delay: animate ? staggerStep * i : Duration.zero,
              barHeight: barHeight,
              textTheme: theme.textTheme,
            ),
          ],
          if (counts.isEmpty)
            Text('No responses yet.', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.letter,
    required this.label,
    required this.count,
    required this.total,
    required this.factor,
    required this.fill,
    required this.isCorrect,
    required this.animate,
    required this.delay,
    required this.barHeight,
    required this.textTheme,
  });

  final String letter;
  final String? label;
  final int count;
  final int total;
  final double factor;
  final Color fill;
  final bool isCorrect;
  final bool animate;
  final Duration delay;
  final double barHeight;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final percent = total == 0 ? 0 : (count / total * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              letter,
              style: textTheme.labelLarge?.copyWith(color: t.ink),
            ),
            if (label != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: t.ink),
                ),
              ),
            ] else
              const Spacer(),
            if (isCorrect) ...[
              Icon(Icons.check, size: 16, color: t.correctInk),
              const SizedBox(width: 4),
            ],
            Text(
              showPercentText(count, percent),
              style: textTheme.labelMedium?.copyWith(color: t.ink),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // The track is the muted line colour; the bar grows over it.
        Container(
          height: barHeight,
          decoration: BoxDecoration(
            color: t.surfaceMuted,
            border: Border.all(color: t.line, width: t.borderWidth),
          ),
          child: GrowBar(
            factor: factor,
            color: fill,
            duration: animate ? durSlow : Duration.zero,
            delay: delay,
          ),
        ),
      ],
    );
  }

  static String showPercentText(int count, int percent) => '$count · $percent%';
}

/// A horizontal meter for a single proportion — accuracy, completion, share.
/// Same mechanics as the distribution rows, one bar.
class BauhausMeter extends StatelessWidget {
  const BauhausMeter({
    super.key,
    required this.factor,
    required this.label,
    this.valueText,
    this.fill,
    this.height = 14,
    this.animate = true,
  });

  /// 0..1.
  final double factor;

  final String label;

  /// Defaults to the rounded percentage.
  final String? valueText;

  final Color? fill;
  final double height;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final pct = (factor.clamp(0.0, 1.0) * 100).round();
    final value = valueText ?? '$pct%';

    return Semantics(
      label: '$label, $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: EyebrowLabel(label)),
              Text(value, style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: height,
            decoration: BoxDecoration(
              color: t.surfaceMuted,
              border: Border.all(color: t.line, width: t.borderWidth),
            ),
            child: GrowBar(
              factor: factor,
              color: fill ?? t.ink,
              duration: animate ? durSlow : Duration.zero,
            ),
          ),
        ],
      ),
    );
  }
}
