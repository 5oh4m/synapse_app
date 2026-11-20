/// Bauhaus motion: mechanical and purposeful. Things slide, wipe and snap along
/// axes. No bounce, no elastic, no floaty fades.
///
/// Every primitive in this file honours `MediaQuery.disableAnimationsOf` — when
/// the platform asks for reduced motion the widget renders its **end state**
/// immediately and starts no controller, schedules no timer.
library;

import 'package:flutter/material.dart';

/// State feedback — tap, toggle.
const Duration durInstant = Duration(milliseconds: 90);

/// Enter/exit of small elements.
const Duration durQuick = Duration(milliseconds: 180);

/// Page and panel transitions.
const Duration durBase = Duration(milliseconds: 260);

/// Reveal moments — answer, podium, score.
const Duration durSlow = Duration(milliseconds: 420);

/// Gap between staggered siblings.
const Duration staggerStep = Duration(milliseconds: 40);

/// Entering.
const Curve easeOut = Curves.easeOutCubic;

/// Moving.
const Curve easeInOut = Curves.easeInOutCubic;

/// Decisive — the Bauhaus default.
const Curve easeSnap = Cubic(0.2, 0, 0, 1);

/// Distance a staggered child travels along its axis.
const double slideDistance = 16.0;

/// Motion helpers. Read [reduced] before you start anything.
class Motion {
  const Motion._();

  static const Duration instant = durInstant;
  static const Duration quick = durQuick;
  static const Duration base = durBase;
  static const Duration slow = durSlow;
  static const Duration stagger = staggerStep;

  /// True when the platform (or a test) asks for no animation.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// [d], or [Duration.zero] under reduced motion. Use for implicit
  /// animations, which jump straight to the target at zero duration.
  static Duration dur(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;

  /// Total time a staggered run takes for [count] children.
  static Duration staggerTotal(
    int count, {
    Duration item = durBase,
    Duration step = staggerStep,
    int maxSlots = StaggeredEntry.defaultMaxSlots,
  }) {
    final slots = count <= 0 ? 0 : (count - 1).clamp(0, maxSlots);
    return item + step * slots;
  }
}

/// Slides [child] [distance] along [axis] and fades it in, delayed by
/// `index * step`, once, on first build.
///
/// The resting state is the visible one: the widget ends at offset zero /
/// opacity one and *stays* there. Nothing here waits on a scroll observer, so
/// a child can never be left parked at `opacity: 0`. The delay is capped at
/// [maxSlots] steps so item 400 of a long list is not invisible for 16
/// seconds. Under reduced motion the child renders visible immediately.
class StaggeredEntry extends StatefulWidget {
  const StaggeredEntry({
    super.key,
    required this.index,
    required this.child,
    this.axis = Axis.vertical,
    this.distance = slideDistance,
    this.duration = durBase,
    this.step = staggerStep,
    this.curve = easeSnap,
    this.maxSlots = defaultMaxSlots,
    this.enabled = true,
  });

  /// Position in the list/grid — drives the delay.
  final int index;

  final Widget child;

  /// Axis the child travels along. Lists slide vertically, rails horizontally.
  final Axis axis;

  /// Travel distance in logical pixels. Negative slides from the other side.
  final double distance;

  final Duration duration;
  final Duration step;
  final Curve curve;

  /// Maximum number of stagger slots before the delay stops growing.
  final int maxSlots;

  /// When false the child is rendered as-is, no animation. Use for rebuild-heavy
  /// hosts that have already played their entry.
  final bool enabled;

  static const int defaultMaxSlots = 12;

  @override
  State<StaggeredEntry> createState() => _StaggeredEntryState();
}

class _StaggeredEntryState extends State<StaggeredEntry>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late Animation<double> _t;
  bool _started = false;

  Duration get _delay =>
      widget.step * widget.index.clamp(0, widget.maxSlots).toDouble();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    if (!widget.enabled || Motion.reduced(context)) {
      // End state, no controller, no ticker.
      _t = const AlwaysStoppedAnimation<double>(1);
      return;
    }

    final total = _delay + widget.duration;
    final controller = AnimationController(vsync: this, duration: total);
    _controller = controller;
    final double start = total.inMicroseconds == 0
        ? 0.0
        : _delay.inMicroseconds / total.inMicroseconds;
    _t = CurvedAnimation(
      parent: controller,
      curve: Interval(start, 1, curve: widget.curve),
    );
    controller.forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;

    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        final v = _t.value;
        final dx = widget.axis == Axis.horizontal
            ? widget.distance * (1 - v)
            : 0.0;
        final dy = widget.axis == Axis.vertical
            ? widget.distance * (1 - v)
            : 0.0;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(dx, dy), child: child),
        );
      },
    );
  }
}

/// Convenience: wrap each child of a list in a [StaggeredEntry].
List<Widget> staggered(
  List<Widget> children, {
  Axis axis = Axis.vertical,
  double distance = slideDistance,
  Duration duration = durBase,
  Duration step = staggerStep,
  int startIndex = 0,
}) {
  return [
    for (var i = 0; i < children.length; i++)
      StaggeredEntry(
        index: startIndex + i,
        axis: axis,
        distance: distance,
        duration: duration,
        step: step,
        child: children[i],
      ),
  ];
}

/// Counts an integer up (or down) to [value], with tabular figures so the digits
/// do not jitter while it runs. Announces itself as a live region by default —
/// scores and timers must reach a screen reader.
class CountUp extends StatelessWidget {
  const CountUp({
    super.key,
    required this.value,
    this.duration = durSlow,
    this.curve = easeOut,
    this.style,
    this.prefix = '',
    this.suffix = '',
    this.textAlign,
    this.semanticsLabel,
    this.liveRegion = true,
    this.from = 0,
  });

  /// Target value.
  final int value;

  final Duration duration;
  final Curve curve;

  /// Defaults to `textTheme.displaySmall`, always with tabular figures forced on.
  final TextStyle? style;

  final String prefix;
  final String suffix;
  final TextAlign? textAlign;

  /// Announced text. Defaults to `'<prefix><value><suffix>'`.
  final String? semanticsLabel;

  final bool liveRegion;

  /// Where the very first run starts from.
  final int from;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = (style ?? theme.textTheme.displaySmall)?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final label = semanticsLabel ?? '$prefix$value$suffix';

    Widget text(int v) => Text(
      '$prefix$v$suffix',
      style: effective,
      textAlign: textAlign,
    );

    final Widget body = Motion.reduced(context)
        ? text(value)
        : TweenAnimationBuilder<int>(
            tween: IntTween(begin: from, end: value),
            duration: duration,
            curve: curve,
            builder: (context, v, _) => text(v),
          );

    return Semantics(
      liveRegion: liveRegion,
      label: label,
      excludeSemantics: true,
      child: body,
    );
  }
}

/// A hard-edged colour wipe. [overlay] is revealed over [child] from one edge,
/// as a moving straight line — the reveal gesture of this design system.
///
/// Used for the correct-answer reveal and as the leading edge of a route
/// transition. Under reduced motion the overlay simply appears.
class WipeReveal extends StatelessWidget {
  const WipeReveal({
    super.key,
    required this.revealed,
    required this.child,
    required this.overlay,
    this.duration = durSlow,
    this.curve = easeSnap,
    this.direction = AxisDirection.right,
    this.onEnd,
  });

  /// Drives the wipe. Flip it to play.
  final bool revealed;

  /// What is underneath.
  final Widget child;

  /// What wipes in. Sized to [child].
  final Widget overlay;

  final Duration duration;
  final Curve curve;

  /// Which way the wipe travels. [AxisDirection.right] is left-to-right.
  final AxisDirection direction;

  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final target = revealed ? 1.0 : 0.0;
    if (Motion.reduced(context)) return _stack(target);
    // `begin` is only consulted on the first build, so a widget that is born
    // already revealed shows the overlay instead of wiping it in.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: target, end: target),
      duration: duration,
      curve: curve,
      onEnd: onEnd,
      builder: (context, t, _) => _stack(t),
    );
  }

  Widget _stack(double t) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (t > 0)
          Positioned.fill(
            child: ClipRect(
              clipper: WipeClipper(progress: t, direction: direction),
              child: overlay,
            ),
          ),
      ],
    );
  }
}

/// Clips to [progress] of the box, measured from the edge opposite
/// [direction]'s travel. Exposed so route transitions can share the geometry.
class WipeClipper extends CustomClipper<Rect> {
  const WipeClipper({
    required this.progress,
    this.direction = AxisDirection.right,
  });

  final double progress;
  final AxisDirection direction;

  @override
  Rect getClip(Size size) {
    final p = progress.clamp(0.0, 1.0);
    switch (direction) {
      case AxisDirection.right:
        return Rect.fromLTWH(0, 0, size.width * p, size.height);
      case AxisDirection.left:
        return Rect.fromLTWH(
          size.width * (1 - p),
          0,
          size.width * p,
          size.height,
        );
      case AxisDirection.down:
        return Rect.fromLTWH(0, 0, size.width, size.height * p);
      case AxisDirection.up:
        return Rect.fromLTWH(
          0,
          size.height * (1 - p),
          size.width,
          size.height * p,
        );
    }
  }

  @override
  bool shouldReclip(WipeClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.direction != direction;
}

/// A bar that grows from zero along [axis] to [factor] of its track. The
/// distribution chart and the podium blocks are both built from this.
class GrowBar extends StatelessWidget {
  const GrowBar({
    super.key,
    required this.factor,
    required this.color,
    this.axis = Axis.horizontal,
    this.duration = durSlow,
    this.curve = easeSnap,
    this.thickness,
    this.border,
    this.child,
    this.delay = Duration.zero,
  });

  /// 0..1 of the available extent.
  final double factor;
  final Color color;
  final Axis axis;
  final Duration duration;
  final Curve curve;

  /// Cross-axis size. Null lets the parent decide.
  final double? thickness;

  final BoxBorder? border;
  final Widget? child;

  /// Start offset, for staggering a set of bars.
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final target = factor.clamp(0.0, 1.0);
    final reduced = Motion.reduced(context);
    final total = reduced ? Duration.zero : delay + duration;
    final double start = total.inMicroseconds == 0
        ? 0.0
        : delay.inMicroseconds / total.inMicroseconds;

    Widget bar(double f) {
      final box = Container(
        decoration: BoxDecoration(color: color, border: border),
        child: child,
      );
      return Align(
        alignment: axis == Axis.horizontal
            ? AlignmentDirectional.centerStart
            : Alignment.bottomCenter,
        child: FractionallySizedBox(
          widthFactor: axis == Axis.horizontal ? f : null,
          heightFactor: axis == Axis.vertical ? f : null,
          child: box,
        ),
      );
    }

    final Widget body = reduced
        ? bar(target)
        : TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: target),
            duration: total,
            curve: Interval(start, 1, curve: curve),
            builder: (context, f, _) => bar(f),
          );

    if (thickness == null) return body;
    return axis == Axis.horizontal
        ? SizedBox(height: thickness, child: body)
        : SizedBox(width: thickness, child: body);
  }
}

/// Swaps its child when [switchKey] changes, mechanically: the outgoing plane
/// leaves at once and the incoming one slides in [distance] along [axis]
/// behind a hard wipe. No cross-fade, no overlap of two planes.
///
/// The live screens use it for question-to-question and for panel changes
/// (submit → locked in → outcome), which used to be hard cuts. The first child
/// appears without animation; under reduced motion nothing animates.
class PlaneSwitcher extends StatelessWidget {
  const PlaneSwitcher({
    super.key,
    required this.switchKey,
    required this.child,
    this.axis = Axis.horizontal,
    this.distance = 32,
    this.duration = durBase,
    this.animateSize = false,
  });

  /// A change in this value plays the swap.
  final Object switchKey;

  final Widget child;
  final Axis axis;
  final double distance;
  final Duration duration;

  /// Also ease the height change between panels of different sizes.
  final bool animateSize;

  @override
  Widget build(BuildContext context) {
    final d = Motion.dur(context, duration);
    Widget switcher = AnimatedSwitcher(
      duration: d,
      layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) => _PlaneIn(
        animation: animation,
        axis: axis,
        distance: distance,
        child: child,
      ),
      child: KeyedSubtree(key: ValueKey(switchKey), child: child),
    );
    if (animateSize) {
      switcher = AnimatedSize(
        duration: d,
        curve: easeSnap,
        alignment: Alignment.topCenter,
        child: switcher,
      );
    }
    return switcher;
  }
}

class _PlaneIn extends AnimatedWidget {
  const _PlaneIn({
    required Animation<double> animation,
    required this.axis,
    required this.distance,
    required this.child,
  }) : super(listenable: animation);

  final Axis axis;
  final double distance;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final v = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    final t = easeSnap.transform(v);
    final travel = distance * (1 - t);
    // Same shape at rest as mid-flight, so the child's state survives the
    // moment the transition completes.
    return ClipRect(
      // No clip at rest: focus rings and block-print offsets draw outside the
      // box and must not be cut off.
      clipBehavior: v >= 1 ? Clip.none : Clip.hardEdge,
      clipper: WipeClipper(
        progress: v >= 1 ? 1 : t,
        direction: axis == Axis.horizontal
            ? AxisDirection.right
            : AxisDirection.down,
      ),
      child: Transform.translate(
        offset: axis == Axis.horizontal ? Offset(travel, 0) : Offset(0, travel),
        child: child,
      ),
    );
  }
}

/// Pulses [child] once per second — scale 1.0 -> 1.04 -> 1.0. Used by the
/// countdown under five seconds. Holds still (and runs no ticker) when
/// [active] is false or motion is reduced.
class PulseOnce extends StatefulWidget {
  const PulseOnce({
    super.key,
    required this.active,
    required this.child,
    this.period = const Duration(seconds: 1),
    this.scale = 1.04,
  });

  final bool active;
  final Widget child;
  final Duration period;
  final double scale;

  @override
  State<PulseOnce> createState() => _PulseOnceState();
}

class _PulseOnceState extends State<PulseOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  late Animation<double> _scale = _buildScale();

  Animation<double> _buildScale() => TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: widget.scale).chain(CurveTween(curve: easeSnap)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(begin: widget.scale, end: 1.0).chain(CurveTween(curve: easeOut)),
      weight: 70,
    ),
  ]).animate(_c);

  @override
  void didUpdateWidget(covariant PulseOnce old) {
    super.didUpdateWidget(old);
    if (old.scale != widget.scale || old.period != widget.period) {
      _c.duration = widget.period;
      _scale = _buildScale();
    }
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final run = widget.active && !Motion.reduced(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || Motion.reduced(context)) return widget.child;
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}
