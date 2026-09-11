/// Route transitions for the Bauhaus language: a **horizontal plane slide with
/// a hard leading edge**, at `durBase` / `easeSnap`. Not the Material fade.
///
/// The incoming page is a solid plane pushed in from the trailing edge; a 4px
/// ink line rides its leading edge and dissolves as the page lands, which is
/// the same "wipe" gesture the answer reveal uses. The outgoing page recedes a
/// short way in the same direction and dims slightly, so the two planes read as
/// stacked sheets rather than a cross-fade.
///
/// **Wiring it up.** [AppTheme] already installs
/// [quizzlePageTransitionsTheme], so every `MaterialPageRoute` (and therefore
/// every `GoRoute` that uses `builder:`) gets the transition for free.
///
/// For explicit control — or for anything that needs a non-default direction —
/// use the `pageBuilder` helpers with go_router:
///
/// ```dart
/// GoRoute(
///   path: '/quizzes',
///   pageBuilder: (context, state) => quizzlePage(
///     context: context,
///     state: state,
///     child: const QuizListScreen(),
///   ),
/// );
///
/// // A panel that belongs "under" the current screen (join code, results):
/// GoRoute(
///   path: '/results/:id',
///   pageBuilder: (context, state) => quizzleModalPage(
///     context: context,
///     state: state,
///     child: const FinalResultsScreen(),
///   ),
/// );
/// ```
///
/// Both helpers take the `GoRouterState` only to derive a stable page key and
/// the route name; pass `key`/`name` directly if you have no state at hand.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'motion.dart';

/// Fraction of the viewport the incoming plane travels.
const double _kEnterTravel = 0.18;

/// Fraction the outgoing plane recedes.
const double _kExitTravel = 0.06;

/// Width of the ink line riding the leading edge.
const double _kEdge = 4.0;

/// The plane-slide transition. Used by [PlaneSlidePageTransitionsBuilder] and
/// the `pageBuilder` helpers; usable directly inside any
/// `AnimatedWidget`-shaped transition builder.
class PlaneSlideTransition extends StatelessWidget {
  const PlaneSlideTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
    this.axis = Axis.horizontal,
    this.reverse = false,
  });

  /// 0 -> 1 as this route enters.
  final Animation<double> animation;

  /// 0 -> 1 as a route is pushed on top of this one.
  final Animation<double> secondaryAnimation;

  final Widget child;

  /// Axis the planes slide along. Vertical reads as a panel.
  final Axis axis;

  /// Slide in from the leading edge instead of the trailing one.
  final bool reverse;

  @override
  Widget build(BuildContext context) {
    // Reduced motion: no travel, no edge, no fade — just the page.
    if (Motion.reduced(context)) return child;

    final sign = reverse ? -1.0 : 1.0;
    final enter = CurvedAnimation(parent: animation, curve: easeSnap);
    final exit = CurvedAnimation(parent: secondaryAnimation, curve: easeSnap);

    Offset offsetFor(double t, double travel) => axis == Axis.horizontal
        ? Offset(t * travel * sign, 0)
        : Offset(0, t * travel * sign);

    return AnimatedBuilder(
      animation: Listenable.merge([enter, exit]),
      child: child,
      builder: (context, child) {
        final e = enter.value;
        final x = exit.value;
        // Entering: slide in from +travel. Being covered: recede by -travel.
        final offset =
            offsetFor(1 - e, _kEnterTravel) - offsetFor(x, _kExitTravel);
        final edgeAlpha = (1 - e).clamp(0.0, 1.0);

        return FractionalTranslation(
          translation: offset,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              child!,
              // The hard leading edge. Only present while travelling, so it
              // never paints over a settled page.
              if (edgeAlpha > 0.01)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: axis == Axis.horizontal && !reverse ? 0 : null,
                  right: axis == Axis.horizontal && reverse ? 0 : null,
                  width: axis == Axis.horizontal ? _kEdge : null,
                  child: axis == Axis.horizontal
                      ? Opacity(
                          opacity: edgeAlpha,
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              if (edgeAlpha > 0.01 && axis == Axis.vertical)
                Positioned(
                  left: 0,
                  right: 0,
                  top: reverse ? null : 0,
                  bottom: reverse ? 0 : null,
                  height: _kEdge,
                  child: Opacity(
                    opacity: edgeAlpha,
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Drop-in replacement for the Material fade. Installed for every platform by
/// [quizzlePageTransitionsTheme].
class PlaneSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const PlaneSlidePageTransitionsBuilder({this.axis = Axis.horizontal});

  final Axis axis;

  @override
  Duration get transitionDuration => durBase;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return PlaneSlideTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      axis: axis,
      child: child,
    );
  }
}

/// Every platform gets the same mechanical slide — the design language is the
/// product, not the host OS convention.
const PageTransitionsTheme quizzlePageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: PlaneSlidePageTransitionsBuilder(),
    TargetPlatform.iOS: PlaneSlidePageTransitionsBuilder(),
    TargetPlatform.macOS: PlaneSlidePageTransitionsBuilder(),
    TargetPlatform.windows: PlaneSlidePageTransitionsBuilder(),
    TargetPlatform.linux: PlaneSlidePageTransitionsBuilder(),
    TargetPlatform.fuchsia: PlaneSlidePageTransitionsBuilder(),
  },
);

/// The standard page: horizontal plane slide at `durBase` / `easeSnap`.
///
/// Pass [context] so reduced-motion collapses the duration to zero (a
/// zero-duration route still completes correctly; it simply does not animate).
CustomTransitionPage<T> quizzlePage<T>({
  required Widget child,
  BuildContext? context,
  GoRouterState? state,
  LocalKey? key,
  String? name,
  Axis axis = Axis.horizontal,
  bool reverse = false,
  Duration duration = durBase,
  bool opaque = true,
  bool barrierDismissible = false,
}) {
  final reduced = context != null && Motion.reduced(context);
  return CustomTransitionPage<T>(
    key: key ?? state?.pageKey,
    name: name ?? state?.name ?? state?.fullPath,
    arguments: state?.extra,
    opaque: opaque,
    barrierDismissible: barrierDismissible,
    transitionDuration: reduced ? Duration.zero : duration,
    reverseTransitionDuration: reduced ? Duration.zero : duration,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return PlaneSlideTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        axis: axis,
        reverse: reverse,
        child: child,
      );
    },
  );
}

/// A page that arrives as a panel from the bottom edge — results, sheets,
/// anything that reads as "on top of" rather than "after".
CustomTransitionPage<T> quizzleModalPage<T>({
  required Widget child,
  BuildContext? context,
  GoRouterState? state,
  LocalKey? key,
  String? name,
  Duration duration = durBase,
}) {
  return quizzlePage<T>(
    child: child,
    context: context,
    state: state,
    key: key,
    name: name,
    axis: Axis.vertical,
    duration: duration,
  );
}

/// No transition at all — for tab-style swaps inside a shell route, where a
/// slide would fight the persistent chrome.
CustomTransitionPage<T> quizzleStillPage<T>({
  required Widget child,
  GoRouterState? state,
  LocalKey? key,
  String? name,
}) {
  return CustomTransitionPage<T>(
    key: key ?? state?.pageKey,
    name: name ?? state?.name ?? state?.fullPath,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    child: child,
    transitionsBuilder: (_, _, _, child) => child,
  );
}
