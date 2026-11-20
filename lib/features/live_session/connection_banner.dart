import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../core/connection.dart' as net;
import '../../shared_widgets/bauhaus_button.dart';
import '../../shared_widgets/labels.dart';
import '../../state/providers.dart';

/// Link health for a live session, as the play/host screens need to show it.
enum LiveConnection {
  connected,
  reconnecting,
  offline;

  bool get isDegraded => this != LiveConnection.connected;
}

/// The realtime client's own link state (`connectionStateProvider`).
///
/// This used to be inferred from errors on the session stream. That stream
/// never errors — a dropped socket simply stops delivering deltas — so the
/// banner said "connected" over a frozen question. The socket is the only
/// thing that knows whether it is up, so the banner now asks it.
final liveConnectionProvider = Provider.autoDispose<LiveConnection>((ref) {
  final state = ref.watch(connectionStateProvider).valueOrNull;
  return switch (state) {
    net.ConnectionState.reconnecting => LiveConnection.reconnecting,
    net.ConnectionState.offline => LiveConnection.offline,
    // Connected, or no report yet: say nothing rather than flash a banner.
    _ => LiveConnection.connected,
  };
});

/// A strip that states the link is degraded **without taking the quiz away**.
///
/// It is deliberately a banner and not a blocking overlay: answers already
/// submitted live on the server, and the tile the player has tapped but not
/// sent stays selected underneath, so a dropped wifi never costs progress.
///
/// Announced as a live region so a screen reader is told the moment the link
/// changes state.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
    required this.state,
    this.onRetry,
    this.detail,
  });

  final LiveConnection state;

  /// Offered whenever the link is degraded: skips the reconnect backoff.
  final VoidCallback? onRetry;

  /// Extra reassurance under the headline.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    if (state == LiveConnection.connected) return const SizedBox.shrink();

    final offline = state == LiveConnection.offline;
    final fill = offline ? t.wrong : t.warn;
    final headline = offline ? 'Offline' : 'Reconnecting…';
    final body =
        detail ??
        (offline
            ? 'We lost the connection to this quiz. Your answers so far are '
                  'saved — reconnect to keep playing.'
            : 'Hold on, we are picking the session back up. Nothing you have '
                  'answered is lost.');

    return Semantics(
      liveRegion: true,
      label: '$headline. $body',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: t.line, width: t.borderWidth),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A square status block, pulsing while we are still trying.
            PulseOnce(
              active: !offline,
              child: Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.only(top: 3),
                color: QuizzleColors.paper,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  EyebrowLabel(headline, color: QuizzleColors.paper),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: QuizzleColors.paper,
                    ),
                  ),
                ],
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: 12),
              BauhausIconButton(
                icon: Icons.refresh,
                tooltip: 'Reconnect now',
                semanticLabel: 'Reconnect to the quiz now',
                color: QuizzleColors.paper,
                bordered: false,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
