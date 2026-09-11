import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/motion.dart';
import '../app/theme.dart';
import '../models/enums.dart';
import '../state/providers.dart';
import 'answer_distribution_bar.dart';
import 'answer_tile.dart';
import 'app_scaffold.dart';
import 'async_view.dart';
import 'bauhaus_button.dart';
import 'bauhaus_card.dart';
import 'countdown_square.dart';
import 'difficulty_chip.dart';
import 'focus_ring.dart';
import 'join_code_display.dart';
import 'labels.dart';
import 'leaderboard_list.dart';

/// The design-system catalogue: every component, in every state, in both
/// themes, at any text scale, with motion on or off.
///
/// Run it on its own — it needs no backend and no router:
///
/// ```sh
/// export PATH="$HOME/flutter/bin:$PATH"
/// flutter run -t lib/shared_widgets/gallery.dart -d macos   # or chrome
/// ```
///
/// The app bar carries the three switches worth screenshotting against: theme,
/// text scale (1.0 / 1.5 / 2.0) and reduced motion.
void main() {
  runApp(
    ProviderScope(
      // The shell section reads the signed-in role; nothing else needs state.
      overrides: [currentUserProvider.overrideWithValue(null)],
      child: const GalleryApp(),
    ),
  );
}

class GalleryApp extends StatefulWidget {
  const GalleryApp({super.key});

  @override
  State<GalleryApp> createState() => _GalleryAppState();
}

class _GalleryAppState extends State<GalleryApp> {
  ThemeMode _mode = ThemeMode.light;
  double _textScale = 1.0;
  bool _reduceMotion = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'quizzle design system',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _mode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(_textScale),
            disableAnimations: _reduceMotion,
          ),
          child: child!,
        );
      },
      home: DesignGallery(
        mode: _mode,
        textScale: _textScale,
        reduceMotion: _reduceMotion,
        onToggleTheme: () => setState(() {
          _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
        }),
        onCycleTextScale: () => setState(() {
          _textScale = switch (_textScale) {
            1.0 => 1.5,
            1.5 => 2.0,
            _ => 1.0,
          };
        }),
        onToggleMotion: () =>
            setState(() => _reduceMotion = !_reduceMotion),
      ),
    );
  }
}

/// The catalogue itself. Embeddable in the real app behind a debug route if
/// anyone wants it there.
class DesignGallery extends StatefulWidget {
  const DesignGallery({
    super.key,
    this.mode = ThemeMode.light,
    this.textScale = 1.0,
    this.reduceMotion = false,
    this.onToggleTheme,
    this.onCycleTextScale,
    this.onToggleMotion,
  });

  final ThemeMode mode;
  final double textScale;
  final bool reduceMotion;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onCycleTextScale;
  final VoidCallback? onToggleMotion;

  @override
  State<DesignGallery> createState() => _DesignGalleryState();
}

class _DesignGalleryState extends State<DesignGallery> {
  int? _selectedAnswer;
  bool _revealed = false;
  bool _wipe = false;
  int _score = 1200;
  int _staggerRun = 0;
  List<LeaderRow> _board = const [
    LeaderRow(rank: 1, name: 'Ada Lovelace', points: 2400, id: 'a'),
    LeaderRow(rank: 2, name: 'Grete Stern', points: 2100, id: 'b', delta: -1),
    LeaderRow(
      rank: 3,
      name: 'Josef Albers',
      points: 1750,
      id: 'c',
      highlight: true,
      subtitle: '3 in a row',
    ),
    LeaderRow(rank: 4, name: 'Anni Albers', points: 1200, id: 'd', delta: 2),
  ];

  static const List<String> _options = [
    'The Bauhaus was founded in Weimar',
    'It moved to Dessau in 1925',
    'Form follows function',
    'Closed in 1933',
  ];

  void _shuffleBoard() {
    setState(() {
      final rotated = [..._board.skip(1), _board.first];
      _board = [
        for (var i = 0; i < rotated.length; i++)
          LeaderRow(
            rank: i + 1,
            name: rotated[i].name,
            points: rotated[i].points + (i == 0 ? 300 : 50),
            id: rotated[i].id,
            highlight: rotated[i].highlight,
            subtitle: rotated[i].subtitle,
            delta: rotated[i].rank - (i + 1),
          ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final theme = Theme.of(context);
    final gutter = t.gutterFor(MediaQuery.sizeOf(context).width);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Design system'),
        actions: [
          BauhausIconButton(
            icon: widget.mode == ThemeMode.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined,
            tooltip: widget.mode == ThemeMode.dark
                ? 'Switch to light theme'
                : 'Switch to dark theme',
            bordered: false,
            onPressed: widget.onToggleTheme,
          ),
          BauhausIconButton(
            icon: Icons.format_size,
            tooltip: 'Text scale ${widget.textScale}x — tap to cycle',
            bordered: false,
            onPressed: widget.onCycleTextScale,
          ),
          BauhausIconButton(
            icon: widget.reduceMotion
                ? Icons.motion_photos_off_outlined
                : Icons.motion_photos_on_outlined,
            tooltip: widget.reduceMotion
                ? 'Motion disabled — tap to enable'
                : 'Motion enabled — tap to disable',
            bordered: false,
            onPressed: widget.onToggleMotion,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(gutter),
        children: [
          Text(
            'Bauhaus · flat planes, hard corners, 2px borders',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Theme ${widget.mode.name} · text ${widget.textScale}x · '
            'motion ${widget.reduceMotion ? "off" : "on"}',
            style: theme.textTheme.bodySmall,
          ),

          _Section('Colour tokens', children: [
            const _Swatches(),
          ]),

          _Section('Type scale', children: [
            const _TypeScale(),
          ]),

          _Section('Buttons', children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                BauhausButton.primary(label: 'Start session', onPressed: () {}),
                BauhausButton.secondary(label: 'Preview', onPressed: () {}),
                BauhausButton.ghost(label: 'Cancel', onPressed: () {}),
                BauhausButton.danger(label: 'Delete quiz', onPressed: () {}),
                BauhausButton.primary(
                  label: 'With icon',
                  icon: Icons.play_arrow,
                  onPressed: () {},
                ),
                const BauhausButton.primary(label: 'Disabled'),
                const BauhausButton.primary(label: 'Working', busy: true),
              ],
            ),
            const SizedBox(height: 12),
            BauhausButton.primary(
              label: 'Full width primary',
              expand: true,
              onPressed: () {},
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                BauhausIconButton(
                  icon: Icons.play_arrow,
                  tooltip: 'Start',
                  onPressed: () {},
                ),
                const SizedBox(width: 10),
                BauhausIconButton(
                  icon: Icons.pause,
                  tooltip: 'Pause',
                  selected: true,
                  onPressed: () {},
                ),
                const SizedBox(width: 10),
                const BauhausIconButton(
                  icon: Icons.skip_next,
                  tooltip: 'Next question (disabled)',
                ),
                const SizedBox(width: 10),
                const _FocusRingDemo(),
              ],
            ),
          ]),

          _Section('Planes', children: [
            BauhausCard(
              child: Text(
                'A flat plane. 2px border, no blur, sizes to content.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),
            BauhausCard(
              blockShadow: true,
              child: Text(
                'Block-print offset — the locked-in state.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),
            BauhausCard(
              accentBar: t.warn,
              onTap: () {},
              semanticLabel: 'Tappable card with accent bar',
              child: Text(
                'Tappable, with the one accent bar per screen.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ]),

          _Section('Bento grid', children: [
            BentoGrid(
              children: [
                BentoTile(
                  eyebrow: 'This week',
                  title: 'Sessions run',
                  columnSpan: 2,
                  child: StatTile(
                    label: 'Completed',
                    numericValue: 18,
                    caption: '+4 on last week',
                    bordered: false,
                  ),
                ),
                const BentoTile(
                  eyebrow: 'Accuracy',
                  child: BauhausMeter(factor: 0.72, label: 'Class average'),
                ),
                BentoTile(
                  eyebrow: 'Library',
                  title: 'Content items',
                  trailing: BauhausIconButton(
                    icon: Icons.add,
                    tooltip: 'Add content',
                    bordered: false,
                    onPressed: () {},
                  ),
                  child: StatTile(
                    label: 'Ready',
                    numericValue: 42,
                    bordered: false,
                  ),
                ),
                const BentoTile(
                  eyebrow: 'Difficulty mix',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      DifficultyChip(Difficulty.easy),
                      DifficultyChip(Difficulty.medium),
                      DifficultyChip(Difficulty.hard),
                    ],
                  ),
                ),
              ],
            ),
          ]),

          _Section('Labels, stats, chips', children: [
            const SectionHeader(
              title: 'Question review',
              eyebrow: 'Step 2 of 3',
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Participants',
                    numericValue: 27,
                    liveRegion: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatTile(
                    label: 'Accuracy',
                    value: '72%',
                    caption: 'across 12 questions',
                    accent: t.correctInk,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                const BauhausChip(label: 'Draft'),
                BauhausChip(
                  label: 'Published',
                  fill: t.correct,
                  ink: t.onAnswer,
                ),
                BauhausChip(label: 'Tappable', onTap: () {}),
                const BauhausChip(label: 'Dense', dense: true),
              ],
            ),
          ]),

          _Section('Answer tiles', children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                BauhausButton.secondary(
                  label: _revealed ? 'Hide reveal' : 'Reveal answer',
                  onPressed: () => setState(() => _revealed = !_revealed),
                ),
                BauhausButton.ghost(
                  label: 'Clear selection',
                  onPressed: () => setState(() => _selectedAnswer = null),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AnswerTileGrid(
              options: _options,
              selectedIndex: _selectedAnswer,
              correctIndex: _revealed ? 1 : null,
              counts: const [4, 12, 3, 8],
              showCounts: _revealed,
              onSelect: (i) => setState(() => _selectedAnswer = i),
            ),
            const SizedBox(height: 18),
            EyebrowLabel('Every state, forced'),
            const SizedBox(height: 8),
            const AnswerTile(index: 0, text: 'Idle'),
            const SizedBox(height: 10),
            const AnswerTile(
              index: 1,
              text: 'Locked in',
              status: AnswerTileStatus.locked,
            ),
            const SizedBox(height: 10),
            const AnswerTile(
              index: 2,
              text: 'Correct',
              status: AnswerTileStatus.correct,
              count: 12,
              showCount: true,
            ),
            const SizedBox(height: 10),
            const AnswerTile(
              index: 3,
              text: 'Wrong pick',
              status: AnswerTileStatus.wrong,
            ),
            const SizedBox(height: 10),
            const AnswerTile(
              index: 0,
              text: 'Dimmed after reveal',
              status: AnswerTileStatus.dimmed,
            ),
          ]),

          _Section('Distribution and meters', children: [
            AnswerDistributionBar(
              counts: const [4, 12, 3, 8],
              labels: _options,
              correctIndex: 1,
            ),
            const SizedBox(height: 18),
            const BauhausMeter(factor: 0.34, label: 'Hard questions'),
          ]),

          _Section('Countdown', children: [
            Wrap(
              spacing: 20,
              runSpacing: 20,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: const [
                _CountdownSample(remaining: 20, total: 20, caption: 'Full'),
                _CountdownSample(remaining: 9, total: 20, caption: '45% · warn'),
                _CountdownSample(remaining: 3, total: 20, caption: '15% · wrong + pulse'),
                _CountdownSample(remaining: 0, total: 20, caption: 'Expired'),
              ],
            ),
          ]),

          _Section('Join code', children: [
            JoinCodeDisplay(
              key: ValueKey(_staggerRun),
              code: 'Q7K2M9',
              caption: 'Players join at quizzle.app/join',
              onCopy: () => showSnack(context, 'Join code copied'),
              onShare: () => showSnack(context, 'Share sheet would open'),
            ),
            const SizedBox(height: 12),
            BauhausButton.ghost(
              label: 'Replay stagger',
              onPressed: () => setState(() => _staggerRun++),
            ),
          ]),

          _Section('Leaderboard', children: [
            Podium(key: ValueKey(_board.first.key), rows: _board),
            const SizedBox(height: 18),
            LeaderboardList(rows: _board),
            const SizedBox(height: 12),
            RankBadge(rank: 3, points: 1750, of: 27),
            const SizedBox(height: 12),
            BauhausButton.secondary(
              label: 'Rotate ranks',
              onPressed: _shuffleBoard,
            ),
          ]),

          _Section('Motion primitives', children: [
            Row(
              children: [
                Expanded(
                  child: CountUp(
                    value: _score,
                    style: theme.textTheme.displayMedium,
                  ),
                ),
                BauhausButton.secondary(
                  label: '+350',
                  onPressed: () => setState(() => _score += 350),
                ),
              ],
            ),
            const SizedBox(height: 16),
            BauhausButton.secondary(
              label: _wipe ? 'Un-wipe' : 'Wipe reveal',
              onPressed: () => setState(() => _wipe = !_wipe),
            ),
            const SizedBox(height: 10),
            WipeReveal(
              revealed: _wipe,
              overlay: Container(
                color: t.correct,
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Correct',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: t.onAnswer,
                  ),
                ),
              ),
              child: Container(
                decoration: t.plane(),
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Waiting for the reveal',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
            BauhausButton.secondary(
              label: 'Replay staggered entry',
              onPressed: () => setState(() => _staggerRun++),
            ),
            const SizedBox(height: 10),
            Column(
              key: ValueKey('stagger-$_staggerRun'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  StaggeredEntry(
                    index: i,
                    child: Container(
                      decoration: t.plane(),
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Row ${i + 1} — 40ms apart',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            BauhausButton.primary(
              label: 'Push a route (plane slide)',
              trailingIcon: Icons.arrow_forward,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _TransitionTarget(),
                ),
              ),
            ),
          ]),

          _Section('Async states', children: [
            SizedBox(
              height: 160,
              child: BauhausCard(
                child: const LoadingView(label: 'Generating questions'),
              ),
            ),
            const SizedBox(height: 12),
            BauhausCard(
              child: ErrorView(
                message: 'The session could not be reached.',
                onRetry: () {},
              ),
            ),
            const SizedBox(height: 12),
            BauhausCard(
              child: EmptyView(
                icon: Icons.quiz_outlined,
                title: 'No quizzes yet',
                subtitle: 'Generate one from a document in your library.',
                action: BauhausButton.primary(
                  label: 'Create a quiz',
                  onPressed: () {},
                ),
              ),
            ),
          ]),

          _Section('Shell', children: [
            Text(
              'AppScaffold — bottom bar under 600px, side rail above. '
              'Nav taps need a router, so they are inert here.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _ShellSample(width: 420, label: 'Compact — bottom bar'),
            const SizedBox(height: 12),
            const _ShellSample(width: 900, label: 'Expanded — side rail'),
          ]),

          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(width: 12, height: 12, color: t.ink),
              const SizedBox(width: 8),
              Expanded(child: EyebrowLabel(title)),
            ],
          ),
          const SizedBox(height: 6),
          Container(height: 2, color: t.line),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  const _Swatches();

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final entries = <(String, Color, Color)>[
      ('ink', t.ink, t.ground),
      ('ink secondary', t.inkSecondary, t.surface),
      ('ink muted', t.inkMuted, t.ground),
      ('ground', t.ground, t.ink),
      ('surface', t.surface, t.ink),
      ('line', t.line, t.ground),
      ('answer A', t.answerFills[0], t.onAnswer),
      ('answer B', t.answerFills[1], t.onAnswer),
      ('answer C', t.answerFills[2], t.onAnswer),
      ('answer D', t.answerFills[3], t.onAnswer),
      ('correct', t.correct, t.onAnswer),
      ('wrong', t.wrong, t.onAnswer),
      ('warn', t.warn, t.onAnswer),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (name, fill, ink) in entries)
          Container(
            width: 132,
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: t.line, width: t.borderWidth),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                EyebrowLabel(name, color: ink),
                const SizedBox(height: 18),
                Text(
                  '#${(fill.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: ink),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TypeScale extends StatelessWidget {
  const _TypeScale();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final rows = <(String, TextStyle?)>[
      ('56 displayLarge · Archivo Black', text.displayLarge),
      ('40 displayMedium', text.displayMedium),
      ('28 displaySmall', text.displaySmall),
      ('22 headlineMedium', text.headlineMedium),
      ('17 titleMedium', text.titleMedium),
      ('17 bodyLarge', text.bodyLarge),
      ('15 bodyMedium', text.bodyMedium),
      ('13 bodySmall', text.bodySmall),
      ('11 labelSmall · 0.12em', text.labelSmall),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, style) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              label == rows.last.$1 ? label.toUpperCase() : label,
              style: style,
            ),
          ),
      ],
    );
  }
}

class _CountdownSample extends StatelessWidget {
  const _CountdownSample({
    required this.remaining,
    required this.total,
    required this.caption,
  });

  final int remaining;
  final int total;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CountdownSquare.fixed(
          remaining: Duration(seconds: remaining),
          total: Duration(seconds: total),
        ),
        const SizedBox(height: 8),
        SizedBox(width: 120, child: EyebrowLabel(caption, textAlign: TextAlign.center)),
      ],
    );
  }
}

class _FocusRingDemo extends StatefulWidget {
  const _FocusRingDemo();

  @override
  State<_FocusRingDemo> createState() => _FocusRingDemoState();
}

class _FocusRingDemoState extends State<_FocusRingDemo> {
  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    return Semantics(
      label: 'Focus ring, always on, for reference',
      excludeSemantics: true,
      child: FocusRing(
        focused: true,
        child: Container(
          decoration: t.plane(),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Text(
            'Focus ring',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      ),
    );
  }
}

class _TransitionTarget extends StatelessWidget {
  const _TransitionTarget();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Plane slide')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'durBase · easeSnap',
                style: theme.textTheme.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              BauhausButton.secondary(
                label: 'Back',
                icon: Icons.arrow_back,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Embeds [AppScaffold] at a forced width so both breakpoints are visible on
/// one page.
class _ShellSample extends StatelessWidget {
  const _ShellSample({required this.width, required this.label});

  final double width;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = QuizzleTokens.of(context);
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EyebrowLabel(label),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: t.line, width: t.borderWidth),
          ),
          child: SizedBox(
            height: 320,
            child: MediaQuery(
              // Force the breakpoint the sample is demonstrating.
              data: media.copyWith(size: Size(width, 320)),
              child: ClipRect(
                child: SizedBox(
                  width: double.infinity,
                  child: AppScaffold(
                    title: 'Quizzes',
                    eyebrow: 'Educator',
                    currentRoute: '/quizzes',
                    showProfileAction: false,
                    body: Center(
                      child: Text(
                        'Screen body',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
