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
import '../features/profile/profile_screen.dart';
import '../features/quiz_management/question_review_screen.dart';
import '../features/quiz_management/quiz_detail_screen.dart';
import '../features/quiz_management/quiz_list_screen.dart';
import '../models/user.dart';
import '../state/providers.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _AuthRefresh(ref);
  ref.onDispose(notifier.dispose);

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
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/library',
        builder: (_, _) => const ContentLibraryScreen(),
      ),
      GoRoute(
        path: '/create',
        builder: (_, s) =>
            CreateQuizScreen(contentItemId: s.uri.queryParameters['content']),
      ),
      GoRoute(path: '/quizzes', builder: (_, _) => const QuizListScreen()),
      GoRoute(
        path: '/quiz/:id',
        builder: (_, s) => QuizDetailScreen(quizId: s.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'review',
            builder: (_, s) =>
                QuestionReviewScreen(quizId: s.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/host/:sessionId',
        builder: (_, s) =>
            HostSessionScreen(sessionId: s.pathParameters['sessionId']!),
      ),
      GoRoute(path: '/join', builder: (_, _) => const JoinScreen()),
      GoRoute(
        path: '/join/:code',
        builder: (_, s) => JoinScreen(
          prefillCode: normalizeJoinCode(s.pathParameters['code'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/play/:sessionId',
        builder: (_, s) =>
            PlaySessionScreen(sessionId: s.pathParameters['sessionId']!),
      ),
      GoRoute(
        path: '/results/:sessionId',
        builder: (_, s) =>
            FinalResultsScreen(sessionId: s.pathParameters['sessionId']!),
      ),
      GoRoute(
        path: '/leaderboard',
        builder: (_, _) => const GlobalLeaderboardScreen(),
      ),
      GoRoute(
        path: '/analytics',
        builder: (_, _) => const AnalyticsDashboardScreen(),
      ),
      GoRoute(
        path: '/analytics/quiz/:id',
        builder: (_, s) => QuizAnalyticsScreen(quizId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
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
