import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app/motion.dart';
import '../app/theme.dart';

/// The countdown: a **square ring that depletes**, not a spinner.
///
/// * The stroke retreats anticlockwise from the top edge, so the remaining
///   time is a shrinking hard-edged frame.
/// * Colour steps `navy -> warn -> wrong` as it crosses 50% and 20%.
/// * At five seconds or less the whole ring pulses once per second
///   (scale 1.0 -> 1.04).
/// * The figure is a live region, and the widget announces "10 seconds left"
///   and "5 seconds left" through [SemanticsService].
/// * Under reduced motion nothing pulses and nothing eases — the frame simply
///   steps down each tick, which is information, not decoration.
///
/// Two ways to drive it: give it a [deadline] and it ticks itself (all clients
/// share the deadline from the session doc, so rings stay in sync without
/// per-frame messaging), or use [CountdownSquare.fixed] and drive [remaining]
/// yourself — handy for tests, galleries and host-controlled replays.
class CountdownSquare extends StatefulWidget {
  const CountdownSquare({
    super.key,
    required DateTime this.deadline,
    required this.total,
    this.size = 88,
    this.strokeWidth = 6,
    this.onExpire,
    this.label = 'Time remaining',
    this.announce = true,
  }) : remaining = null;

  /// A countdown with the remaining time supplied from outside. No timer runs.
  const CountdownSquare.fixed({
    super.key,
    required Duration this.remaining,
    required this.total,
    this.size = 88,
    this.strokeWidth = 6,
    this.label = 'Time remaining',
    this.announce = false,
  }) : deadline = null,
       onExpire = null;

  /// Wall-clock instant the question closes.
  final DateTime? deadline;

  /// Externally supplied remaining time ([CountdownSquare.fixed] only).
  final Duration? remaining;

  /// The question's full duration — the denominator for the depletion.
  final Duration total;

  /// Side length of the ring. The figure inside scales from the [TextTheme].
  final double size;

  final double strokeWidth;

  /// Fired once when the deadline passes.
  final VoidCallback? onExpire;

  /// Prefix for the announced value, e.g. "Time remaining, 8 seconds".
  final String label;

  /// Announce at the 10s and 5s thresholds.
  final bool announce;

  @override
  State<CountdownSquare> createState() => _CountdownSquareState();
}

class _CountdownSquareState extends State<CountdownSquare> {
  Timer? _timer;
  bool _fired = false;
  int? _lastAnnouncedThreshold;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    if (widget.deadline == null) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final left = _remaining();
      setState(() {});
      _maybeAnnounce(left);
      if (left <= Duration.zero) {
        // Nothing left to animate — stop scheduling frames.
        _timer?.cancel();
        _timer = null;
        if (!_fired) {
          _fired = true;
          widget.onExpire?.call();
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant CountdownSquare old) {
    super.didUpdateWidget(old);
    if (old.deadline != widget.deadline) {
      _fired = false;
      _lastAnnouncedThreshold = null;
      _startTimer();
    }
    if (widget.remaining != null && old.remaining != widget.remaining) {
      _maybeAnnounce(widget.remaining!);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration _remaining() {
    if (widget.remaining != null) return widget.remaining!;
    final d = widget.deadline;
    if (d == null) return Duration.zero;
    final r = d.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  void _maybeAnnounce(Duration left) {
    if (!widget.announce) return;
    final whole = left.inMilliseconds / 1000;
    for (final threshold in const [10, 5]) {
      if (whole <= threshold &&
          whole > threshold - 1 &&
          _lastAnnouncedThreshold != threshold) {
        _lastAnnouncedThreshold = threshold;
        if (MediaQuery.maybeSupportsAnnounceOf(context) ?? false) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            '$threshold seconds left',
            Directionality.of(context),
            assertiveness: Assertiveness.assertive,
          );
        }
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final remaining = _remaining();
    final totalMs = widget.total.inMilliseconds;
    final fraction = totalMs == 0
        ? 0.0
        : (remaining.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final seconds = remaining.inMilliseconds / 1000;

    // navy -> amber -> red at 50% / 20%.
    final Color color = fraction > 0.5
        ? t.ink
        : fraction > 0.2
        ? t.warnInk
        : t.wrongInk;

    final figure = seconds >= 10
        ? seconds.ceil().toString()
        : seconds.toStringAsFixed(seconds <= 0 ? 0 : 1);

    final wholeSeconds = seconds.ceil();

    // The ring is geometry, so it grows with the text setting instead of
    // squeezing the figure: the box scales, the digits fill it.
    final side =
        widget.size *
        MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);

    final ring = SizedBox(
      width: side,
      height: side,
      child: CustomPaint(
        painter: _SquareRingPainter(
          fraction: fraction,
          color: color,
          track: t.lineMuted,
          strokeWidth: widget.strokeWidth,
        ),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(widget.strokeWidth + 6),
            child: FittedBox(
              // The figure is typed from the theme, then fitted to the ring, so
              // it never clips and never hard-codes a size.
              child: Text(
                figure,
                style: theme.textTheme.displayMedium?.copyWith(color: color),
              ),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      liveRegion: true,
      label: '${widget.label}, $wholeSeconds seconds',
      excludeSemantics: true,
      child: PulseOnce(active: seconds > 0 && seconds <= 5, child: ring),
    );
  }
}

/// Paints a square frame whose stroke depletes from the top-centre, clockwise,
/// leaving a muted track behind it.
class _SquareRingPainter extends CustomPainter {
  const _SquareRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.strokeWidth,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double strokeWidth;

  Path _framePath(Size size) {
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    // Start at top-centre and run clockwise, so depletion reads symmetrically.
    return Path()
      ..moveTo(rect.center.dx, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.center.dx, rect.top);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _framePath(size);

    final trackPaint = Paint()
      ..color = track
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.butt;
    canvas.drawPath(path, trackPaint);

    if (fraction <= 0) return;

    final metrics = path.computeMetrics().toList();
    final totalLength = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var want = totalLength * fraction.clamp(0.0, 1.0);

    final live = Path();
    for (final metric in metrics) {
      if (want <= 0) break;
      final take = want.clamp(0.0, metric.length);
      live.addPath(metric.extractPath(0, take), Offset.zero);
      want -= take;
    }

    final livePaint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.butt;
    canvas.drawPath(live, livePaint);
  }

  @override
  bool shouldRepaint(_SquareRingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.track != track ||
      old.strokeWidth != strokeWidth;
}
