import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../shared_widgets/focus_ring.dart';

/// The question, as the heading of the live screen.
///
/// Two accessibility jobs, both required by DESIGN.md:
/// * it reports `Semantics(header: true)`, so a screen reader can jump to it;
/// * **focus moves here whenever the text changes** — i.e. when the host
///   advances — so an assistive-technology user is put at the top of the new
///   question instead of being left wherever the previous one ended.
///
/// The type comes from the [TextTheme] (`displaySmall` by default), so the
/// question grows with the system text scale and never clips: nothing here
/// fixes a height or an aspect ratio.
class QuestionHeading extends StatefulWidget {
  const QuestionHeading({
    super.key,
    required this.text,
    this.focusNode,
    this.style,
    this.moveFocusOnChange = true,
    this.focusOnMount = false,
  });

  /// Pull focus here as soon as the heading appears. For screens that give
  /// each question its own heading (a transition swaps the whole question),
  /// where [moveFocusOnChange] never sees the text change.
  final bool focusOnMount;

  final String text;

  /// Supply one to drive focus from outside; otherwise an internal node is used.
  final FocusNode? focusNode;

  final TextStyle? style;

  /// Pull focus here when [text] changes.
  final bool moveFocusOnChange;

  @override
  State<QuestionHeading> createState() => _QuestionHeadingState();
}

class _QuestionHeadingState extends State<QuestionHeading> {
  FocusNode? _internal;
  bool _focused = false;

  FocusNode get _node =>
      widget.focusNode ?? (_internal ??= FocusNode(debugLabel: 'question'));

  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _node.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant QuestionHeading old) {
    super.didUpdateWidget(old);
    if (widget.moveFocusOnChange && old.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _node.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return FocusRing(
      focused: _focused,
      child: Focus(
        focusNode: _node,
        descendantsAreFocusable: false,
        onFocusChange: (v) => setState(() => _focused = v),
        child: Semantics(
          header: true,
          child: Text(
            widget.text,
            style: (widget.style ?? theme.textTheme.displaySmall)?.copyWith(
              color: t.ink,
            ),
          ),
        ),
      ),
    );
  }
}
