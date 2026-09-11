import 'package:flutter/material.dart';

import 'countdown_square.dart';

export 'countdown_square.dart';

/// Compatibility wrapper for the old circular spinner.
///
/// DESIGN.md replaces the circle with a **square depleting ring**
/// ([CountdownSquare]); this class keeps the previous call sites compiling and
/// forwards to it unchanged. The only behavioural differences are the ones the
/// design asks for: square geometry, navy/amber/red steps at 50%/20%, a pulse
/// under five seconds, and screen-reader announcements at 10s and 5s.
///
/// Prefer [CountdownSquare] in new code. Note the default [size] here is the
/// old 76 rather than the new 88.
@Deprecated('Use CountdownSquare — same arguments, square geometry.')
class CountdownRing extends StatelessWidget {
  const CountdownRing({
    super.key,
    required this.deadline,
    required this.total,
    this.size = 76,
    this.onExpire,
  });

  final DateTime deadline;
  final Duration total;
  final double size;
  final VoidCallback? onExpire;

  @override
  Widget build(BuildContext context) {
    return CountdownSquare(
      deadline: deadline,
      total: total,
      size: size,
      onExpire: onExpire,
    );
  }
}
