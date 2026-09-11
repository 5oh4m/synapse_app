import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../models/enums.dart';
import 'labels.dart';

/// Difficulty as a filled pill with white type.
///
/// The previous version tinted the background at 14% and coloured the text,
/// which put ~3:1 text on a light ground. A solid semantic fill with white
/// type is 6.7:1 or better on all three levels, in both themes.
class DifficultyChip extends StatelessWidget {
  const DifficultyChip(this.difficulty, {super.key, this.dense = false});

  final Difficulty difficulty;

  /// Tighter padding for use inside a list row.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final (Color fill, String label) = switch (difficulty) {
      Difficulty.easy => (t.correct, 'Easy'),
      Difficulty.medium => (t.warn, 'Medium'),
      Difficulty.hard => (t.wrong, 'Hard'),
    };

    return BauhausChip(
      label: label,
      fill: fill,
      ink: t.onAnswer,
      dense: dense,
      semanticLabel: '$label difficulty',
    );
  }
}
