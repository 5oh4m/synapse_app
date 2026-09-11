import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import 'bauhaus_button.dart';
import 'labels.dart';

/// The join code, at display scale, with its letters staggering in 40ms apart
/// on session create.
///
/// The field is the one other permitted pill (chips being the first). The code
/// is announced as one spelled-out label — `Join code, Q 7 K 2 M 9` — so a
/// screen reader reads the characters individually instead of inventing a word.
class JoinCodeDisplay extends StatelessWidget {
  const JoinCodeDisplay({
    super.key,
    required this.code,
    this.label = 'Join code',
    this.caption,
    this.animate = true,
    this.onCopy,
    this.onShare,
    this.showCopyButton = true,
    this.compact = false,
  });

  final String code;

  /// The stencilled eyebrow above the code.
  final String label;

  /// A line under the code — the URL players should visit, usually.
  final String? caption;

  /// Play the per-character stagger on first build.
  final bool animate;

  /// Runs after the code is put on the clipboard. Use it to show a snack.
  /// Copying itself always happens here, so callers cannot forget it.
  final VoidCallback? onCopy;

  /// Adds a share affordance beside copy when provided.
  final VoidCallback? onShare;

  final bool showCopyButton;

  /// Uses the 40px display size instead of 56px — for app bars and cards.
  final bool compact;

  /// `Q7K2M9` -> `Q 7 K 2 M 9`, so assistive tech spells it out.
  static String spellOut(String code) => code.trim().split('').join(' ');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: code));
    onCopy?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final chars = code.split('');
    final style =
        (compact ? theme.textTheme.displayMedium : theme.textTheme.displayLarge)
            ?.copyWith(color: t.ink);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        EyebrowLabel(label),
        const SizedBox(height: 8),
        Semantics(
          label: '$label, ${spellOut(code)}',
          excludeSemantics: true,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 16 : 24,
              vertical: compact ? 8 : 12,
            ),
            decoration: BoxDecoration(
              color: t.surface,
              // The join-code field is explicitly allowed to be a pill.
              borderRadius: QuizzleTokens.pillRadius,
              border: Border.all(color: t.line, width: t.borderWidth),
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: compact ? 2 : 4,
              children: [
                for (var i = 0; i < chars.length; i++)
                  StaggeredEntry(
                    index: i,
                    enabled: animate,
                    axis: Axis.vertical,
                    distance: 12,
                    duration: durQuick,
                    child: Text(chars[i], style: style),
                  ),
              ],
            ),
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 8),
          Text(
            caption!,
            style: theme.textTheme.bodyMedium?.copyWith(color: t.ink),
          ),
        ],
        if (showCopyButton || onShare != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (showCopyButton)
                BauhausButton.secondary(
                  label: 'Copy code',
                  icon: Icons.content_copy,
                  semanticLabel: 'Copy join code ${spellOut(code)}',
                  onPressed: _copy,
                ),
              if (showCopyButton && onShare != null) const SizedBox(width: 10),
              if (onShare != null)
                BauhausIconButton(
                  icon: Icons.ios_share,
                  tooltip: 'Share join link',
                  semanticLabel: 'Share join link for code ${spellOut(code)}',
                  onPressed: onShare,
                ),
            ],
          ),
        ],
      ],
    );
  }
}
