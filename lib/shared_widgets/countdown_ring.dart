import 'dart:async';

import 'package:flutter/material.dart';

/// Ticks locally toward [deadline]. All clients share the same deadline from
/// the session doc, so their rings stay in sync without per-frame messaging.
class CountdownRing extends StatefulWidget {
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
  State<CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<CountdownRing> {
  Timer? _timer;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {});
      if (!_fired && _remaining() <= Duration.zero) {
        _fired = true;
        widget.onExpire?.call();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CountdownRing old) {
    super.didUpdateWidget(old);
    if (old.deadline != widget.deadline) _fired = false;
  }

  Duration _remaining() {
    final r = widget.deadline.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining();
    final frac = widget.total.inMilliseconds == 0
        ? 0.0
        : (remaining.inMilliseconds / widget.total.inMilliseconds).clamp(
            0.0,
            1.0,
          );
    final seconds = remaining.inMilliseconds / 1000;
    final scheme = Theme.of(context).colorScheme;
    final color = frac > 0.5
        ? scheme.primary
        : frac > 0.2
        ? const Color(0xFFF2A100)
        : scheme.error;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: frac,
              strokeWidth: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          Text(
            seconds >= 10
                ? seconds.toStringAsFixed(0)
                : seconds.toStringAsFixed(1),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: widget.size / 3.4,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
