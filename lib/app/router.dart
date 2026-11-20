import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/ids.dart';
import '../features/analytics/analytics_dashboard_screen.dart';
import '../features/analytics/quiz_analytics_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/content/content_library_screen.dart';
import '../features/content/create_quiz_screen.dart';
import '../features/home/home_screen.dart';
import '../features/leaderboard/global_leaderboard_screen.dart';
import '../features/live_session/final_results_screen.dart';
import '../features/live_session/host_session_screen.dart';
import '../features/live_session/join_screen.dart';
import '../features/live_session/play_session_screen.dart';
import '../features/live_session/practice_session_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/quiz_management/question_review_screen.dart';
import '../features/quiz_management/quiz_detail_screen.dart';
import '../features/quiz_management/quiz_list_screen.dart';
import '../models/user.dart';
import '../state/providers.dart';
import 'page_transitions.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _AuthRefresh(ref);
  ref.onDispose(notifier.dispose);

  /// Every route is a horizontal plane slide (`durBase` / `easeSnap`) — never
  /// the Material fade. `quizzlePage` collapses the duration to zero under
  /// reduced motion.
  GoRoute slide(
    String path,
    Widget Function(BuildContext, GoRouterState) build, {
    List<RouteBase> routes = const [],
  }) {
    return GoRoute(
      path: path,
      pageBuilder: (context, state) => quizzlePage(
        context: context,
        state: state,
        child: build(context, state),
      ),
      routes: routes,
    );
  }

  /// Panels that read as "on top of" the run of play rather than "after" it:
  /// they arrive from the bottom edge.
  GoRoute panel(
    String path,
    Widget Function(BuildContext, GoRouterState) build,
  ) {
    return GoRoute(
      path: path,
      pageBuilder: (context, state) => quizzleModalPage(
        context: context,
        state: state,
        child: build(context, state),
      ),
    );
  }

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.isLoading || auth.hasError) return null;
      final user = auth.valueOrNull;
      final loc = state.matchedLocation;
      final loggingIn = loc == '/login';
      final joining = loc.startsWith('/join');

      if (user == null) {
        // Preserve a deep-linked join code so the user lands back on it.
        if (joining) {
          final code = state.pathParameters['code'];
          return code == null ? '/login' : '/login?next=/join/$code';
        }
        return loggingIn ? null : '/login';
      }
      if (loggingIn) {
        final next = state.uri.queryParameters['next'];
        return next ?? '/';
      }
      return null;
    },
    routes: [
      slide('/', (_, _) => const HomeScreen()),
      slide('/login', (_, _) => const LoginScreen()),
      slide('/library', (_, _) => const ContentLibraryScreen()),
      slide(
        '/create',
        (_, s) => CreateQuizScreen(contentItemId: s.uri.queryParameters['content']),
      ),
      slide('/quizzes', (_, _) => const QuizListScreen()),
      slide(
        '/quiz/:id',
        (_, s) => QuizDetailScreen(quizId: s.pathParameters['id']!),
        routes: [
          slide(
            'review',
            (_, s) => QuestionReviewScreen(quizId: s.pathParameters['id']!),
          ),
        ],
      ),
      slide(
        '/host/:sessionId',
        (_, s) => HostSessionScreen(sessionId: s.pathParameters['sessionId']!),
      ),
      slide('/join', (_, _) => const JoinScreen()),
      slide(
        '/join/:code',
        (_, s) => JoinScreen(
          prefillCode: normalizeJoinCode(s.pathParameters['code'] ?? ''),
        ),
      ),
      slide(
        '/play/:sessionId',
        (_, s) => PlaySessionScreen(sessionId: s.pathParameters['sessionId']!),
      ),
      slide(
        '/practice/:quizId',
        (_, s) => PracticeSessionScreen(quizId: s.pathParameters['quizId']!),
      ),
      panel(
        '/results/:sessionId',
        (_, s) => FinalResultsScreen(sessionId: s.pathParameters['sessionId']!),
      ),
      slide('/leaderboard', (_, _) => const GlobalLeaderboardScreen()),
      slide('/analytics', (_, _) => const AnalyticsDashboardScreen()),
      slide(
        '/analytics/quiz/:id',
        (_, s) => QuizAnalyticsScreen(quizId: s.pathParameters['id']!),
      ),
      slide('/profile', (_, _) => const ProfileScreen()),
    ],
  );
});

/// Repaints the router whenever auth state changes.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    _sub = ref.listen<AsyncValue<AppUser?>>(
      authStateProvider,
      (_, _) => notifyListeners(),
      fireImmediately: false,
    );
  }
  late final ProviderSubscription<AsyncValue<AppUser?>> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}
