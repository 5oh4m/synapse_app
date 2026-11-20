// Regression tests for the live screens and their motion, written from the
// second audit's proofs: each one failed against the code the audit reviewed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizzle/app/motion.dart';
import 'package:quizzle/app/theme.dart';
import 'package:quizzle/data/in_memory/in_memory_backend.dart';
import 'package:quizzle/features/live_session/host_session_screen.dart';
import 'package:quizzle/features/live_session/play_session_screen.dart';
import 'package:quizzle/models/enums.dart';
import 'package:quizzle/models/question.dart';
import 'package:quizzle/shared_widgets/answer_tile.dart';
import 'package:quizzle/shared_widgets/countdown_square.dart';
import 'package:quizzle/shared_widgets/leaderboard_list.dart';
import 'package:quizzle/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

double? _wipeProgress(WidgetTester tester) {
  final clips = tester
      .widgetList<ClipRect>(find.byType(ClipRect))
      .where((c) => c.clipper is WipeClipper);
  if (clips.isEmpty) return null;
  return (clips.first.clipper! as WipeClipper).progress;
}

const _question =
    'Which organelle is responsible for producing most of the ATP a eukaryotic cell uses?';
const _options = [
  'The ribosome, which translates messenger RNA',
  'The mitochondrion, through oxidative phosphorylation',
  'The Golgi apparatus, which packages proteins',
  'The nucleus, which stores the genome',
];

/// A running session in the offline backend. The last registered student is
/// the signed-in user.
Future<({InMemoryBackend backend, String sessionId})> _liveSession(
  WidgetTester tester, {
  int players = 3,
}) async {
  final backend = InMemoryBackend();
  late String sessionId;
  await tester.runAsync(() async {
    await backend.init();
    final host = await backend.auth.register(
      name: 'Prof',
      email: 'prof@regress.dev',
      password: 'password',
      role: UserRole.educator,
    );
    final draft = await backend.quizzes.createDraft(
      ownerId: host.id,
      title: 'Cells',
      subject: 'Biology',
    );
    await backend.quizzes.addQuestions(draft.id, [
      for (var i = 0; i < 3; i++)
        Question(
          id: '',
          quizId: draft.id,
          text: _question,
          options: _options,
          correctIndex: 1,
          explanation: 'Mitochondria run the electron transport chain.',
          difficulty: Difficulty.medium,
          orderIndex: i,
          timeLimitSeconds: 30,
        ),
    ]);
    final quiz = await backend.quizzes.get(draft.id);
    final session = await backend.sessions.createSession(
      quiz: quiz,
      hostId: host.id,
      questions: await backend.quizzes.questionsOnce(draft.id),
    );
    sessionId = session.id;
    for (var i = 0; i < players; i++) {
      final s = await backend.auth.register(
        name: 'Student ${i + 1}',
        email: 's$i@regress.dev',
        password: 'password',
        role: UserRole.student,
      );
      await backend.sessions.joinSession(joinCode: session.joinCode, student: s);
    }
    await backend.sessions.startSession(session.id);
  });
  return (backend: backend, sessionId: sessionId);
}

Future<void> _frames(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  expect(tester.takeException(), isNull, reason: 'disposing the screen threw');
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('MOTION-1: the correct tile wipes in over the reveal', (tester) async {
    await tester.pumpWidget(_host(const AnswerTile(index: 0, text: 'Mitochondria')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        const AnswerTile(
          index: 0,
          text: 'Mitochondria',
          status: AnswerTileStatus.correct,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final mid = _wipeProgress(tester)!;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1), reason: 'the overlay was born fully revealed');
    await tester.pumpAndSettle();
    expect(_wipeProgress(tester), 1.0);
  });

  testWidgets('MOTION-2: a rank swap slides and scores count on from their last value', (
    tester,
  ) async {
    List<LeaderRow> rows(bool swapped) => swapped
        ? const [
            LeaderRow(rank: 1, name: 'Bo', points: 200, id: 'b'),
            LeaderRow(rank: 2, name: 'Ada', points: 100, id: 'a'),
          ]
        : const [
            LeaderRow(rank: 1, name: 'Ada', points: 100, id: 'a'),
            LeaderRow(rank: 2, name: 'Bo', points: 50, id: 'b'),
          ];
    await tester.pumpWidget(_host(LeaderboardList(rows: rows(false))));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(LeaderboardList(rows: rows(true))));
    await tester.pump(const Duration(milliseconds: 60));

    final moving = tester
        .widgetList<Transform>(find.byType(Transform))
        .where((t) => t.transform.getTranslation().y.abs() > 1);
    expect(moving, isNotEmpty, reason: 'no row slid on the rank change');

    final numbers = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => int.tryParse(t.data ?? ''))
        .whereType<int>()
        .where((n) => n > 2)
        .toList();
    // Bo was at 50 and Ada at 100: mid-count neither may restart from zero.
    expect(numbers.every((n) => n >= 50), isTrue, reason: 'scores restarted at 0: $numbers');
    await tester.pumpAndSettle();
  });

  testWidgets('MD-4: the countdown measures against the clock it is given', (tester) async {
    final serverNow = DateTime.now().add(const Duration(seconds: 10));
    await tester.pumpWidget(
      _host(
        CountdownSquare(
          deadline: serverNow.add(const Duration(seconds: 12)),
          total: const Duration(seconds: 30),
          now: () => DateTime.now().add(const Duration(seconds: 10)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // 12 s left on the server clock; the device clock would have said 22.
    expect(find.text('12'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('FN-6: the reveal renders the key and the outcome, with no error frame', (
    tester,
  ) async {
    final r = await _liveSession(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(r.backend)],
        child: MaterialApp(
          theme: AppTheme.light,
          home: PlaySessionScreen(sessionId: r.sessionId),
        ),
      ),
    );
    await _frames(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(_options[1]));
    await tester.pump();
    await tester.tap(find.text('Submit answer'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await _frames(tester, 6);

    await tester.runAsync(() => r.backend.sessions.revealAnswer(r.sessionId));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull, reason: 'frame $i of the reveal threw');
    }
    expect(find.textContaining('Correct'), findsWidgets);
    expect(find.textContaining('Answer: option B'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('MD-8: on a 375×667 phone Submit is on screen', (tester) async {
    tester.view.physicalSize = const Size(750, 1334);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final r = await _liveSession(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(r.backend)],
        child: MaterialApp(
          theme: AppTheme.light,
          home: PlaySessionScreen(sessionId: r.sessionId),
        ),
      ),
    );
    await _frames(tester);
    final submit = find.text('Submit answer');
    expect(submit, findsOneWidget);
    expect(tester.getRect(submit).bottom, lessThanOrEqualTo(667));
    await _teardown(tester);
  });

  testWidgets('MD-8: on a 1080p projector the standings are beside the question', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final r = await _liveSession(tester, players: 20);
    await tester.runAsync(() => r.backend.sessions.revealAnswer(r.sessionId));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(r.backend)],
        child: MaterialApp(
          theme: AppTheme.light,
          home: HostSessionScreen(sessionId: r.sessionId),
        ),
      ),
    );
    await _frames(tester, 20);

    final controls = tester.getRect(find.text('Next question'));
    final heading = tester.getRect(find.text('Leaderboard'));
    expect(heading.left, greaterThan(1920 / 2), reason: 'standings are not in a side column');
    expect(heading.top, lessThan(400), reason: 'standings start below the fold');
    final rowsOnScreen = find
        .textContaining('Student ')
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .where((rect) => rect.bottom <= controls.top)
        .length;
    expect(rowsOnScreen, greaterThanOrEqualTo(8));
    await _teardown(tester);
  });
}
