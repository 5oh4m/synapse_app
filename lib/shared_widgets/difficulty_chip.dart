import 'package:flutter/material.dart';

import '../models/enums.dart';

class DifficultyChip extends StatelessWidget {
  const DifficultyChip(this.difficulty, {super.key, this.dense = false});
  final Difficulty difficulty;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (difficulty) {
      Difficulty.easy => (const Color(0xFF1F9E5B), 'Easy'),
      Difficulty.medium => (const Color(0xFFF2A100), 'Medium'),
      Difficulty.hard => (const Color(0xFFE8412E), 'Hard'),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: dense ? 11 : 12,
        ),
      ),
    );
  }
}
