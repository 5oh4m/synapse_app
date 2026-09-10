import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../../data/repositories.dart';
import '../../state/providers.dart';
import '../../shared_widgets/async_view.dart';

class QuizAnalyticsScreen extends ConsumerWidget {
  const QuizAnalyticsScreen({super.key, required this.quizId});
  final String quizId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = ref.watch(quizProvider(quizId));
    final analytics = ref.watch(quizAnalyticsProvider(quizId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiz analytics'),
        leading: BackButton(onPressed: () => context.go('/analytics')),
      ),
      body: analytics.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: '$e'),
        data: (a) => ContentContainer(
          maxWidth: 820,
          child: ListView(
            children: [
              Text(
                quiz.valueOrNull?.title ?? 'Quiz',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              _StatRow(analytics: a),
              const SizedBox(height: 24),
              if (a.sessionsRun == 0)
                const EmptyView(
                  icon: Icons.query_stats,
                  title: 'No completed sessions yet',
                  subtitle: 'Host a live session to collect data.',
                )
              else ...[
                Text(
                  'Correct rate by question',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 220,
                  child: _CorrectRateChart(stats: a.questionStats),
                ),
                const SizedBox(height: 20),
                if (a.hardestQuestion != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Hardest question',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(a.hardestQuestion!.text),
                          const SizedBox(height: 4),
                          Text(
                            '${(a.hardestQuestion!.correctRate * 100).round()}% correct',
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                for (final s in a.questionStats)
                  ListTile(
                    dense: true,
                    leading: Text('${s.orderIndex + 1}'),
                    title: Text(
                      s.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text('${(s.correctRate * 100).round()}%'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.analytics});
  final QuizAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Sessions', '${analytics.sessionsRun}'),
      ('Players', '${analytics.participants}'),
      ('Avg score', analytics.averageScore.round().toString()),
      ('Avg correct', '${(analytics.averageCorrectRate * 100).round()}%'),
      ('Completion', '${(analytics.completionRate * 100).round()}%'),
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final (label, value) in items)
          Container(
            width: 150,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }
}

class _CorrectRateChart extends StatelessWidget {
  const _CorrectRateChart({required this.stats});
  final List<QuestionStat> stats;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: 1,
        minY: 0,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              getTitlesWidget: (v, _) => Text(
                '${(v * 100).round()}%',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) => Text(
                'Q${v.toInt() + 1}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < stats.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: stats[i].correctRate,
                  color: scheme.primary,
                  width: 14,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
