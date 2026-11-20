import 'package:flutter/material.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import '../models/session_participant.dart';
import 'labels.dart';

/// One row of a leaderboard. Unchanged public shape from the previous version.
class LeaderRow {
  const LeaderRow({
    required this.rank,
    required this.name,
    required this.points,
    this.highlight = false,
    this.subtitle,
    this.delta,
    this.id,
  });

  final int rank;
  final String name;
  final int points;

  /// Draws the row as the inverse plane — "this is you".
  final bool highlight;

  final String? subtitle;

  /// Rank change since the previous question: negative means moved up.
  final int? delta;

  /// Stable identity. When supplied, rank changes animate as a slide because
  /// the row's element survives the reorder; without it rows are keyed by
  /// name, which is usually good enough.
  final String? id;

  String get key => id ?? name;
}

List<LeaderRow> rowsFromParticipants(
  List<SessionParticipant> ps, {
  String? highlightStudentId,
}) {
  return [
    for (var i = 0; i < ps.length; i++)
      LeaderRow(
        rank: i + 1,
        name: ps[i].displayName,
        points: ps[i].totalScore,
        highlight:
            highlightStudentId != null &&
            ps[i].studentId == highlightStudentId,
        subtitle: ps[i].streak >= 2 ? '${ps[i].streak} in a row' : null,
        // The participant id, which every row has. The student id is blank on
        // rows that arrived as realtime deltas, so it cannot key a row.
        id: ps[i].id,
      ),
  ];
}

/// The leaderboard: flat planes stacked on a 2px rhythm.
///
/// * Rank changes animate as a vertical slide. The translation is expressed as
///   a fraction of the row's own height, so it is correct at any text scale.
/// * Scores count up with tabular figures, so digits do not jitter.
/// * Each row is one semantic node: "Rank 2, Ada, 1450 points, up 1 place".
class LeaderboardList extends StatelessWidget {
  const LeaderboardList({
    super.key,
    required this.rows,
    this.dense = false,
    this.animate = true,
    this.emptyLabel = 'No scores yet.',
    this.stagger = true,
    this.shrinkWrap = true,
    this.physics = const NeverScrollableScrollPhysics(),
    this.onTapRow,
  });

  final List<LeaderRow> rows;

  /// Tighter vertical padding.
  final bool dense;

  /// Count scores up and slide rank changes.
  final bool animate;

  final String emptyLabel;

  /// Play the 40ms entry stagger on first build.
  final bool stagger;

  final bool shrinkWrap;
  final ScrollPhysics? physics;

  final ValueChanged<LeaderRow>? onTapRow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(emptyLabel, style: theme.textTheme.bodyMedium),
      );
    }

    final gap = dense ? 6.0 : 8.0;

    // The key must sit on the outermost widget of each row. It used to sit on
    // the tile *inside* the stagger wrapper, so a reorder matched rows by
    // position, threw both tiles away and rebuilt them: no slide, and every
    // score counted up from zero again.
    Widget item(int i) {
      final row = rows[i];
      final tile = _LeaderRowTile(
        row: row,
        dense: dense,
        animate: animate,
        gap: gap,
        onTap: onTapRow == null ? null : () => onTapRow!(row),
      );
      return KeyedSubtree(
        key: ValueKey(row.key),
        child: StaggeredEntry(index: i, enabled: stagger, child: tile),
      );
    }

    // Embedded boards (the live screens, results) are short and scroll with
    // their page: a keyed Column moves elements on reorder for free.
    if (shrinkWrap && physics is NeverScrollableScrollPhysics) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++)
            Padding(
              key: ValueKey('gap-${rows[i].key}'),
              padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
              child: item(i),
            ),
        ],
      );
    }

    // A long scrolling board stays lazy. findChildIndexCallback lets the
    // sliver find a moved row by key instead of rebuilding it.
    final indexByKey = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> ? indexByKey[key.value] : null,
      itemBuilder: (context, i) => KeyedSubtree(
        key: ValueKey(rows[i].key),
        child: Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
          child: StaggeredEntry(
            index: i,
            enabled: stagger,
            child: _LeaderRowTile(
              row: rows[i],
              dense: dense,
              animate: animate,
              gap: gap,
              onTap: onTapRow == null ? null : () => onTapRow!(rows[i]),
            ),
          ),
        ),
      ),
    );
  }
}

class _LeaderRowTile extends StatefulWidget {
  const _LeaderRowTile({
    required this.row,
    required this.dense,
    required this.animate,
    required this.gap,
    this.onTap,
  });

  final LeaderRow row;
  final bool dense;
  final bool animate;

  /// Space between rows, so a slide travels whole row pitches.
  final double gap;
  final VoidCallback? onTap;

  @override
  State<_LeaderRowTile> createState() => _LeaderRowTileState();
}

class _LeaderRowTileState extends State<_LeaderRowTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: durBase,
  );

  /// Where the row starts from, in logical pixels.
  double _fromPx = 0;

  @override
  void didUpdateWidget(covariant _LeaderRowTile old) {
    super.didUpdateWidget(old);
    if (old.row.rank != widget.row.rank) {
      if (Motion.reduced(context)) {
        _fromPx = 0;
        _slide.value = 1;
      } else {
        // Moving up two places means it *was* two rows lower; start there and
        // travel to zero. The pitch is this row's own laid-out height plus the
        // gap, so the slide is right at any text scale.
        // didUpdateWidget runs during build, so read last frame's layout from
        // the render box rather than `context.size`, which asserts here.
        final box = context.findRenderObject();
        final height = box is RenderBox && box.hasSize ? box.size.height : 56.0;
        final pitch = height + widget.gap;
        _fromPx = (old.row.rank - widget.row.rank) * pitch;
        _slide.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final row = widget.row;

    final fill = row.highlight ? t.inverseGround : t.surface;
    final ink = row.highlight ? t.inverseInk : t.ink;

    final deltaText = switch (row.delta) {
      null => null,
      0 => null,
      final d when d < 0 => 'up ${-d}',
      final d => 'down $d',
    };

    final content = Container(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: t.line, width: t.borderWidth),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: widget.dense ? 10 : 14,
      ),
      constraints: BoxConstraints(minHeight: t.minTouchTarget),
      child: Row(
        children: [
          // Rank as a hard square block, not a medal emoji.
          Container(
            constraints: const BoxConstraints(minWidth: 32),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: row.rank <= 3 ? t.ink : const Color(0x00000000),
            alignment: Alignment.center,
            child: Text(
              '${row.rank}',
              style: theme.textTheme.titleSmall?.copyWith(
                color: row.rank <= 3 ? t.surface : ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(color: ink),
                ),
                if (row.subtitle != null || deltaText != null)
                  Text(
                    [row.subtitle, deltaText].whereType<String>().join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: ink),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          widget.animate
              ? CountUp(
                  value: row.points,
                  duration: durSlow,
                  liveRegion: false,
                  style: theme.textTheme.titleMedium?.copyWith(color: ink),
                )
              : Text(
                  '${row.points}',
                  style: theme.textTheme.titleMedium?.copyWith(color: ink),
                ),
          const SizedBox(width: 4),
          Text(
            'pts',
            style: theme.textTheme.labelSmall?.copyWith(color: ink),
          ),
        ],
      ),
    );

    Widget tile = Semantics(
      label: [
        'Rank ${row.rank}',
        row.name,
        '${row.points} points',
        if (row.highlight) 'you',
        if (row.subtitle != null) row.subtitle!,
        if (deltaText != null) '$deltaText ${row.delta!.abs() == 1 ? 'place' : 'places'}',
      ].join(', '),
      excludeSemantics: true,
      button: widget.onTap != null,
      child: content,
    );

    if (widget.onTap != null) {
      tile = Material(
        color: const Color(0x00000000),
        child: InkWell(onTap: widget.onTap, child: tile),
      );
    }

    // Always wrapped, even at rest: adding the wrapper only when a rank changed
    // would rebuild the row (and restart its count-up) at exactly that moment.
    return AnimatedBuilder(
      animation: _slide,
      child: tile,
      builder: (context, child) {
        final dy = _fromPx * (1 - easeSnap.transform(_slide.value));
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
    );
  }
}

/// The three blocks rise from zero height, staggered **2nd, then 1st, then
/// 3rd** — the order the eye should travel in.
///
/// Blocks are flat planes with a 2px border; the name, score and rank are
/// typed from the theme so the podium survives large text.
class Podium extends StatefulWidget {
  const Podium({
    super.key,
    required this.rows,
    this.maxBlockHeight = 140,
    this.animate = true,
  });

  /// Ranked rows. Only the first three are used.
  final List<LeaderRow> rows;

  /// Height of the first-place block. Second and third are 0.72 and 0.55 of it.
  final double maxBlockHeight;

  final bool animate;

  @override
  State<Podium> createState() => _PodiumState();
}

class _PodiumState extends State<Podium> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    // durSlow for the rise, plus two stagger slots.
    duration: durSlow + const Duration(milliseconds: 240),
  );
  bool _started = false;

  // 2nd, then 1st, then 3rd.
  static const Map<int, Interval> _intervals = {
    2: Interval(0.0, 0.66, curve: easeSnap),
    1: Interval(0.17, 0.83, curve: easeSnap),
    3: Interval(0.34, 1.0, curve: easeSnap),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate || Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) return const SizedBox.shrink();
    final t = QuizzleTokens.of(context);
    final top = widget.rows.take(3).toList();

    // Display order: 2nd, 1st, 3rd — the classic podium arrangement.
    final ordered = <LeaderRow>[
      if (top.length > 1) top[1],
      top[0],
      if (top.length > 2) top[2],
    ];

    return Semantics(
      label: [
        'Podium.',
        for (final r in top) 'Rank ${r.rank}, ${r.name}, ${r.points} points.',
      ].join(' '),
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < ordered.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: _PodiumBlock(
                row: ordered[i],
                controller: _c,
                interval: _intervals[ordered[i].rank] ?? _intervals[3]!,
                height: switch (ordered[i].rank) {
                  1 => widget.maxBlockHeight,
                  2 => widget.maxBlockHeight * 0.72,
                  _ => widget.maxBlockHeight * 0.55,
                },
                fill: ordered[i].rank == 1 ? t.inverseGround : t.surface,
                ink: ordered[i].rank == 1 ? t.inverseInk : t.ink,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PodiumBlock extends StatelessWidget {
  const _PodiumBlock({
    required this.row,
    required this.controller,
    required this.interval,
    required this.height,
    required this.fill,
    required this.ink,
  });

  final LeaderRow row;
  final AnimationController controller;
  final Interval interval;
  final double height;
  final Color fill;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall,
        ),
        Text(
          '${row.points} pts',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        // The rise: height from 0 to its full block.
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final v = interval.transform(controller.value);
            return SizedBox(
              height: height * v,
              child: v <= 0.01
                  ? null
                  : ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: height,
                        maxHeight: height,
                        child: Container(
                          height: height,
                          decoration: BoxDecoration(
                            color: fill,
                            border: Border.all(
                              color: t.line,
                              width: t.borderWidth,
                            ),
                          ),
                          alignment: Alignment.topCenter,
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${row.rank}',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: ink,
                            ),
                          ),
                        ),
                      ),
                    ),
            );
          },
        ),
      ],
    );
  }
}

/// A compact "your position" strip for the student view: rank, name, score.
class RankBadge extends StatelessWidget {
  const RankBadge({
    super.key,
    required this.rank,
    required this.points,
    this.label = 'Your rank',
    this.of,
  });

  final int rank;
  final int points;
  final String label;

  /// Total number of players, if known.
  final int? of;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = QuizzleTokens.of(context);
    final position = of == null ? '$rank' : '$rank of $of';

    return Semantics(
      liveRegion: true,
      label: '$label $position, $points points',
      excludeSemantics: true,
      child: Container(
        decoration: t.plane(fill: t.surface),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  EyebrowLabel(label),
                  const SizedBox(height: 4),
                  Text(position, style: theme.textTheme.headlineMedium),
                ],
              ),
            ),
            CountUp(
              value: points,
              suffix: ' pts',
              style: theme.textTheme.headlineMedium,
              liveRegion: false,
            ),
          ],
        ),
      ),
    );
  }
}
