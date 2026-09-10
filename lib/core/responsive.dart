import 'package:flutter/widgets.dart';

/// Breakpoints used across the app. Desktop and web are first-class targets,
/// so layouts adapt rather than assuming a phone.
class Breakpoints {
  const Breakpoints._();
  static const double compact = 600; // phone
  static const double medium = 1024; // small tablet / split desktop
}

enum FormFactor { compact, medium, expanded }

FormFactor formFactorOf(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < Breakpoints.compact) return FormFactor.compact;
  if (w < Breakpoints.medium) return FormFactor.medium;
  return FormFactor.expanded;
}

bool isCompact(BuildContext context) =>
    formFactorOf(context) == FormFactor.compact;

/// Picks a value per form factor. [medium] and [expanded] fall back to
/// narrower values when omitted.
T responsive<T>(
  BuildContext context, {
  required T compact,
  T? medium,
  T? expanded,
}) {
  switch (formFactorOf(context)) {
    case FormFactor.compact:
      return compact;
    case FormFactor.medium:
      return medium ?? compact;
    case FormFactor.expanded:
      return expanded ?? medium ?? compact;
  }
}

/// Centers content and caps its width on large screens.
class ContentContainer extends StatelessWidget {
  const ContentContainer({
    super.key,
    required this.child,
    this.maxWidth = 900,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
