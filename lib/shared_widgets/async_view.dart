import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'bauhaus_button.dart';
import 'labels.dart';

/// Loading, as three marching squares rather than a spinner — a Bauhaus
/// rhythm, and a shape that holds still under reduced motion instead of
/// rotating forever.
///
/// The status is a live region so a screen reader is told that work is under
/// way, which the old `CircularProgressIndicator` never did.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label, this.compact = false});

  /// Announced and displayed. Defaults to "Loading".
  final String? label;

  /// Drops the padding for inline use inside a card or a row.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final text = label ?? 'Loading';

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MarchingSquares(color: t.ink),
        SizedBox(height: compact ? 8 : 14),
        Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: t.ink),
        ),
      ],
    );

    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(compact ? 8 : 24),
          child: body,
        ),
      ),
    );
  }
}

/// Three squares stepping left to right. Static under reduced motion.
class MarchingSquares extends StatefulWidget {
  const MarchingSquares({
    super.key,
    required this.color,
    this.blockSize = 12,
    this.gap = 6,
  });

  final Color color;
  final double blockSize;
  final double gap;

  @override
  State<MarchingSquares> createState() => _MarchingSquaresState();
}

class _MarchingSquaresState extends State<MarchingSquares>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _block(double opacity) => Padding(
    padding: EdgeInsets.only(right: widget.gap),
    child: Opacity(
      opacity: opacity,
      child: SizedBox(
        width: widget.blockSize,
        height: widget.blockSize,
        child: ColoredBox(color: widget.color),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [_block(1), _block(0.6), _block(0.3)],
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) _block(0.25 + 0.75 * _phase(i)),
        ],
      ),
    );
  }

  double _phase(int i) {
    final v = (_c.value * 3 - i) % 3;
    return v < 1 ? 1 - v : 0;
  }
}

/// A failure, stated plainly on a flat plane, with a retry.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.title = 'Something went wrong',
    this.retryLabel = 'Retry',
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;

  /// Heading above the message.
  final String title;

  final String retryLabel;

  /// Drops the outer padding for inline use.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.proseMaxWidth),
          child: Semantics(
            liveRegion: true,
            label: '$title. $message',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A square status block: the geometric signal for "stopped".
                ExcludeSemantics(
                  child: Row(
                    children: [
                      Container(width: 14, height: 14, color: t.wrong),
                      const SizedBox(width: 8),
                      EyebrowLabel('Error', color: t.wrongInk),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ExcludeSemantics(
                  child: Text(title, style: theme.textTheme.headlineMedium),
                ),
                const SizedBox(height: 6),
                ExcludeSemantics(
                  child: Text(message, style: theme.textTheme.bodyMedium),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 18),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: BauhausButton.secondary(
                      label: retryLabel,
                      icon: Icons.refresh,
                      semanticLabel: '$retryLabel after error',
                      onPressed: onRetry,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Nothing here yet — said with a geometric mark, a title and one action.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  /// Kept for call-site compatibility; drawn inside the square mark.
  final IconData icon;

  final String title;
  final String? subtitle;

  /// Usually a [BauhausButton].
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.proseMaxWidth),
          child: Semantics(
            label: [title, subtitle].whereType<String>().join('. '),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Container(
                    decoration: t.plane(fill: t.surface),
                    padding: const EdgeInsets.all(14),
                    child: Icon(icon, size: 28, color: t.ink),
                  ),
                ),
                const SizedBox(height: 16),
                ExcludeSemantics(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  ExcludeSemantics(
                    child: Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Flat, square-cornered snack on the inverse plane. Announced politely.
void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final t = QuizzleTokens.of(context);
  final theme = Theme.of(context);

  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Semantics(
          liveRegion: true,
          child: Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: error ? t.onAnswer : t.inverseInk,
            ),
          ),
        ),
        backgroundColor: error ? t.wrong : t.inverseGround,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: QuizzleTokens.radius,
          side: BorderSide(color: t.line, width: t.borderWidth),
        ),
        elevation: 0,
      ),
    );
}

/// Maps an [AsyncValue]-shaped trio onto the three views above, so screens stop
/// hand-rolling `when(loading:, error:, data:)` chrome.
///
/// Deliberately not typed against Riverpod so this file stays widget-only:
///
/// ```dart
/// ref.watch(quizzesProvider).when(
///   loading: () => const LoadingView(label: 'Loading quizzes'),
///   error: (e, _) => ErrorView(message: '$e', onRetry: refresh),
///   data: (quizzes) => quizzes.isEmpty
///       ? const EmptyView(icon: Icons.quiz_outlined, title: 'No quizzes yet')
///       : QuizList(quizzes),
/// );
/// ```
class AsyncPlaceholder extends StatelessWidget {
  const AsyncPlaceholder({
    super.key,
    required this.loading,
    this.label,
    this.error,
    this.onRetry,
    this.child,
  });

  final bool loading;
  final String? label;
  final String? error;
  final VoidCallback? onRetry;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (loading) return LoadingView(label: label);
    if (error != null) return ErrorView(message: error!, onRetry: onRetry);
    return child ?? const SizedBox.shrink();
  }
}
