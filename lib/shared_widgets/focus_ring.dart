import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';

/// The visible focus indicator required on every interactive element: a 2px
/// ink outline at a 2px offset, hard corners.
///
/// The ring's space is **always reserved** — a transparent border still
/// occupies its two pixels — so gaining focus never nudges layout. Wrap the
/// outermost visual of a control and feed it the control's focus state
/// (`InkWell.onFocusChange`, `Focus.onFocusChange`, …).
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.focused,
    required this.child,
    this.color,
    this.radius = QuizzleTokens.radius,
    this.width,
    this.offset,
    this.animate = true,
  });

  final bool focused;
  final Widget child;

  /// Defaults to `QuizzleTokens.focusRing`.
  final Color? color;

  final BorderRadius radius;

  /// Ring thickness. Defaults to the token (2px).
  final double? width;

  /// Gap between the ring and the control. Defaults to the token (2px).
  final double? offset;

  /// Cross-fade the ring in. Collapses to an instant swap under reduced motion.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final w = width ?? t.focusRingWidth;
    final o = offset ?? t.focusRingOffset;
    final decoration = BoxDecoration(
      border: Border.all(
        color: focused ? (color ?? t.focusRing) : const Color(0x00000000),
        width: w,
      ),
      borderRadius: radius,
    );

    if (!animate) {
      return Container(
        padding: EdgeInsets.all(o),
        decoration: decoration,
        child: child,
      );
    }
    return AnimatedContainer(
      duration: Motion.dur(context, durQuick),
      curve: easeSnap,
      padding: EdgeInsets.all(o),
      decoration: decoration,
      child: child,
    );
  }
}
