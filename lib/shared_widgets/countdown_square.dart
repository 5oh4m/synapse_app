import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import '../app/motion.dart';
import '../app/theme.dart';

/// The countdown: a **square ring that depletes**, not a spinner.
///
/// * The stroke retreats from the top edge, so the remaining time is a
///   shrinking hard-edged frame.
/// * Colour steps `navy -> warn -> wrong` as it crosses 50% and 20%.
/// * At five seconds or less the whole ring pulses once per second
///   (scale 1.0 -> 1.04).
/// * The figure is a live region, and the widget announces "10 seconds left"
///   and "5 seconds left" through [SemanticsService].
/// * Under reduced motion nothing pulses and the ring steps down once per
///   second, which is information, not decoration.
///
/// **How it moves.** A [Ticker] repaints the ring on every vsync frame, reading
/// the remaining time from the clock each frame. The ring used to be rebuilt by
/// a 100 ms timer, which drew it in visible 10 fps steps and kept running when
/// the route was hidden. Only the painter repaints per frame; the figure,
/// colour and pulse rebuild only when their value actually changes. Because
/// each frame reads the clock rather than advancing an animation, the ring
/// stays on the deadline even after the app was paused.
///
/// Two ways to drive it: give it a [deadline] and it ticks itself (all clients
/// share the deadline from the session doc — pass [now] as the server clock so
/// a device with a drifting clock still closes on time), or use
/// [CountdownSquare.fixed] and drive [remaining] yourself.
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
    this.now,
  }) : remaining = null;

  /// A countdown with the remaining time supplied from outside. No ticker runs.
  const CountdownSquare.fixed({
    super.key,
    required Duration this.remaining,
    required this.total,
    this.size = 88,
    this.strokeWidth = 6,
    this.label = 'Time remaining',
    this.announce = false,
  }) : deadline = null,
       onExpire = null,
       now = null;

  /// Instant the question closes, in server time.
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

  /// The clock the [deadline] is measured against. Defaults to the device
  /// clock; live screens pass the server clock.
  final DateTime Function()? now;

  @override
  State<CountdownSquare> createState() => _CountdownSquareState();
}

/// What the ring shows at one instant. Only a change in this rebuilds widgets.
@immutable
class _Face {
  const _Face({required this.figure, required this.whole, required this.band});

  final String figure;
  final int whole;

  /// 0 = more than half left, 1 = warn, 2 = last 20%, 3 = last 5 seconds.
  final int band;

  @override
  bool operator ==(Object other) =>
      other is _Face &&
      other.figure == figure &&
      other.whole == whole &&
      other.band == band;

  @override
  int get hashCode => Object.hash(figure, whole, band);
}

class _CountdownSquareState extends State<CountdownSquare>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _tick());
  final ValueNotifier<double> _fraction = ValueNotifier(1);
  late final ValueNotifier<_Face> _face = ValueNotifier(_faceFor(_remaining()));

  bool _fired = false;
  int? _lastAnnouncedThreshold;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
    _restart();
  }

  @override
  void didUpdateWidget(covariant CountdownSquare old) {
    super.didUpdateWidget(old);
    if (old.deadline != widget.deadline) {
      _fired = false;
      _lastAnnouncedThreshold = null;
    }
    _restart();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fraction.dispose();
    _face.dispose();
    super.dispose();
  }

  void _restart() {
    _tick();
    final running = widget.deadline != null && _remaining() > Duration.zero;
    if (running && !_ticker.isActive) {
      _ticker.start();
    } else if (!running && _ticker.isActive) {
      _ticker.stop();
    }
  }

  Duration _remaining() {
    if (widget.remaining != null) return widget.remaining!;
    final d = widget.deadline;
    if (d == null) return Duration.zero;
    final now = (widget.now ?? DateTime.now)();
    final r = d.difference(now);
    return r.isNegative ? Duration.zero : r;
  }

  double _fractionFor(Duration remaining) {
    final totalMs = widget.total.inMilliseconds;
    if (totalMs == 0) return 0;
    // Reduced motion: the frame steps once per whole second instead of gliding.
    final ms = _reduced && remaining > Duration.zero
        ? (remaining.inMilliseconds / 1000).ceil() * 1000
        : remaining.inMilliseconds;
    return (ms / totalMs).clamp(0.0, 1.0);
  }

  _Face _faceFor(Duration remaining) {
    final seconds = remaining.inMilliseconds / 1000;
    final fraction = _fractionFor(remaining);
    final figure = seconds >= 10
        ? seconds.ceil().toString()
        : seconds.toStringAsFixed(seconds <= 0 ? 0 : 1);
    final band = seconds > 0 && seconds <= 5
        ? 3
        : fraction > 0.5
        ? 0
        : fraction > 0.2
        ? 1
        : 2;
    return _Face(figure: figure, whole: seconds.ceil(), band: band);
  }

  void _tick() {
    final left = _remaining();
    _fraction.value = _fractionFor(left);
    _face.value = _faceFor(left);
    _maybeAnnounce(left);
    if (widget.deadline != null && left <= Duration.zero) {
      if (_ticker.isActive) _ticker.stop();
      if (!_fired) {
        _fired = true;
        // Never during build: the callback may set state on an ancestor.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onExpire?.call();
        });
      }
    }
  }

  void _maybeAnnounce(Duration left) {
    if (!widget.announce || !mounted) return;
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

    // The ring is geometry, so it grows with the text setting instead of
    // squeezing the figure: the box scales, the digits fill it.
    final side =
        widget.size *
        MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);

    Color colorFor(int band) => switch (band) {
      0 => t.ink,
      1 => t.warnInk,
      _ => t.wrongInk,
    };

    return ValueListenableBuilder<_Face>(
      valueListenable: _face,
      builder: (context, face, _) {
        final color = colorFor(face.band);
        final ring = SizedBox(
          width: side,
          height: side,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _SquareRingPainter(
                fraction: _fraction,
                color: color,
                track: t.lineMuted,
                strokeWidth: widget.strokeWidth,
              ),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(widget.strokeWidth + 6),
                  child: FittedBox(
                    // Typed from the theme, then fitted to the ring, so it
                    // never clips and never hard-codes a size.
                    child: Text(
                      face.figure,
                      style: theme.textTheme.displayMedium?.copyWith(
                        color: color,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        return Semantics(
          liveRegion: true,
          label: '${widget.label}, ${face.whole} seconds',
          excludeSemantics: true,
          child: PulseOnce(active: face.band == 3, child: ring),
        );
      },
    );
  }
}

/// Paints a square frame whose stroke depletes from the top-centre, clockwise,
/// leaving a muted track behind it. Repaints straight from [fraction], so a
/// frame of depletion costs a repaint and no rebuild.
class _SquareRingPainter extends CustomPainter {
  _SquareRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.strokeWidth,
  }) : super(repaint: fraction);

  final ValueNotifier<double> fraction;
  final Color color;
  final Color track;
  final double strokeWidth;

  Path? _path;
  Size? _pathSize;
  double _length = 0;
  List<PathMetric> _metrics = const [];

  void _ensurePath(Size size) {
    if (_path != null && _pathSize == size) return;
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    // Start at top-centre and run clockwise, so depletion reads symmetrically.
    _path = Path()
      ..moveTo(rect.center.dx, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.center.dx, rect.top);
    _pathSize = size;
    _metrics = _path!.computeMetrics().toList();
    _length = _metrics.fold<double>(0, (sum, m) => sum + m.length);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _ensurePath(size);
    final stroke = Paint()
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.butt;

    canvas.drawPath(_path!, stroke..color = track);

    final f = fraction.value;
    if (f <= 0) return;
    var want = _length * f.clamp(0.0, 1.0);
    final live = Path();
    for (final metric in _metrics) {
      if (want <= 0) break;
      final take = want.clamp(0.0, metric.length);
      live.addPath(metric.extractPath(0, take), Offset.zero);
      want -= take;
    }
    canvas.drawPath(live, stroke..color = color);
  }

  @override
  bool shouldRepaint(_SquareRingPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.track != track ||
      old.strokeWidth != strokeWidth;
}
