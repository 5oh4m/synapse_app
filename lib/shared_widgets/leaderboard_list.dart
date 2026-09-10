import 'package:flutter/material.dart';

import '../models/session_participant.dart';

class LeaderRow {
  const LeaderRow({
    required this.rank,
    required this.name,
    required this.points,
    this.highlight = false,
    this.subtitle,
    this.delta,
  });
  final int rank;
  final String name;
  final int points;
  final bool highlight;
  final String? subtitle;
  final int? delta;
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
        highlight: ps[i].studentId == highlightStudentId,
        subtitle: ps[i].streak >= 2 ? '🔥 ${ps[i].streak} streak' : null,
      ),
  ];
}

class LeaderboardList extends StatelessWidget {
  const LeaderboardList({super.key, required this.rows, this.dense = false});
  final List<LeaderRow> rows;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No scores yet.'),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final r = rows[i];
        final medal = switch (r.rank) {
          1 => '🥇',
          2 => '🥈',
          3 => '🥉',
          _ => null,
        };
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: dense ? 10 : 14,
          ),
          decoration: BoxDecoration(
            color: r.highlight
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: r.highlight
                ? Border.all(color: scheme.primary, width: 1.5)
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  medal ?? '${r.rank}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (r.subtitle != null)
                      Text(
                        r.subtitle!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Text(
                '${r.points}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(width: 2),
              Text('pts', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
      },
    );
  }
}

class Podium extends StatelessWidget {
  const Podium({super.key, required this.rows});
  final List<LeaderRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final top = rows.take(3).toList();
    final order = [
      if (top.length > 1) top[1],
      top[0],
      if (top.length > 2) top[2],
    ];
    final heights = <int, double>{1: 120, 2: 92, 3: 72};
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final r in order)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(switch (r.rank) {
                    1 => '🥇',
                    2 => '🥈',
                    _ => '🥉',
                  }, style: const TextStyle(fontSize: 26)),
                  Text(
                    r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${r.points} pts',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: heights[r.rank],
                    decoration: BoxDecoration(
                      color: r.rank == 1
                          ? scheme.primary
                          : scheme.primary.withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(10),
                      ),
                    ),
                    alignment: Alignment.topCenter,
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${r.rank}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
