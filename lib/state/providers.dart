import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/anthropic_quiz_generator.dart';
import '../ai/mock_quiz_generator.dart';
import '../ai/quiz_generator.dart';
import '../ai/remote_quiz_generator.dart';
import '../core/env.dart';
import '../data/in_memory/in_memory_backend.dart';
import '../data/remote/remote_backend.dart';
import '../data/repositories.dart';
import '../models/content_item.dart';
import '../models/leaderboard_entry.dart';
import '../models/question.dart';
import '../models/quiz.dart';
import '../models/quiz_session.dart';
import '../models/response.dart';
import '../models/session_participant.dart';
import '../models/user.dart';

/// Swap the concrete backend here. Overridden in tests.
final backendProvider = Provider<Backend>((ref) {
  return Env.isRemote ? RemoteBackend() : InMemoryBackend();
});

/// The app waits on this before rendering routes.
final backendReadyProvider = FutureProvider<Backend>((ref) async {
  final backend = ref.watch(backendProvider);
  await backend.init();
  return backend;
});

final quizGeneratorProvider = Provider<QuizGenerator>((ref) {
  if (Env.isRemote) return RemoteQuizGenerator();
  if (Env.useAnthropicDirect) return AnthropicQuizGenerator();
  return MockQuizGenerator();
});

/// Human-readable label for the "how are questions generated" banner.
final generatorLabelProvider = Provider<String>((ref) {
  if (Env.isRemote) return 'Server (${Env.aiProvider})';
  if (Env.useAnthropicDirect) return 'Claude (${Env.anthropicModel}) — dev';
  return 'Offline sample generator';
});

// --- repositories ---------------------------------------------------------

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => ref.watch(backendProvider).auth,
);
final contentRepositoryProvider = Provider<ContentRepository>(
  (ref) => ref.watch(backendProvider).content,
);
final quizRepositoryProvider = Provider<QuizRepository>(
  (ref) => ref.watch(backendProvider).quizzes,
);
final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => ref.watch(backendProvider).sessions,
);
final leaderboardRepositoryProvider = Provider<LeaderboardRepository>(
  (ref) => ref.watch(backendProvider).leaderboard,
);
final analyticsRepositoryProvider = Provider<AnalyticsRepository>(
  (ref) => ref.watch(backendProvider).analytics,
);

// --- auth ---------------------------------------------------------------

final authStateProvider = StreamProvider<AppUser?>((ref) {
  return ref.watch(authRepositoryProvider).authState();
});

final currentUserProvider = Provider<AppUser?>((ref) {
  return ref.watch(authStateProvider).valueOrNull;
});

// --- content ----------------------------------------------------------

final libraryProvider = StreamProvider.autoDispose
    .family<List<ContentItem>, String>((ref, ownerId) {
      return ref.watch(contentRepositoryProvider).watchLibrary(ownerId);
    });

// --- quizzes --------------------------------------------------------

final quizzesProvider = StreamProvider.autoDispose.family<List<Quiz>, String>((
  ref,
  ownerId,
) {
  return ref.watch(quizRepositoryProvider).watchQuizzes(ownerId);
});

final quizProvider = StreamProvider.autoDispose.family<Quiz?, String>((
  ref,
  quizId,
) {
  return ref.watch(quizRepositoryProvider).watchQuiz(quizId);
});

final questionsProvider = StreamProvider.autoDispose
    .family<List<Question>, String>((ref, quizId) {
      return ref.watch(quizRepositoryProvider).watchQuestions(quizId);
    });

final publishedQuizzesProvider = FutureProvider.autoDispose<List<Quiz>>((
  ref,
) async {
  return ref.watch(quizRepositoryProvider).publishedQuizzes();
});

// --- live sessions --------------------------------------------------

final sessionProvider = StreamProvider.autoDispose.family<QuizSession?, String>(
  (ref, sessionId) {
    return ref.watch(sessionRepositoryProvider).watchSession(sessionId);
  },
);

final participantsProvider = StreamProvider.autoDispose
    .family<List<SessionParticipant>, String>((ref, sessionId) {
      return ref.watch(sessionRepositoryProvider).watchParticipants(sessionId);
    });

final sessionResponsesProvider = StreamProvider.autoDispose
    .family<List<QuizResponse>, String>((ref, sessionId) {
      return ref.watch(sessionRepositoryProvider).watchResponses(sessionId);
    });

// --- leaderboard / analytics --------------------------------------

class LeaderboardQuery {
  const LeaderboardQuery({this.period = 'all-time', this.subject});
  final String period;
  final String? subject;

  @override
  bool operator ==(Object other) =>
      other is LeaderboardQuery &&
      other.period == period &&
      other.subject == subject;
  @override
  int get hashCode => Object.hash(period, subject);
}

final globalLeaderboardProvider = StreamProvider.autoDispose
    .family<List<LeaderboardEntry>, LeaderboardQuery>((ref, q) {
      return ref
          .watch(leaderboardRepositoryProvider)
          .watchGlobal(period: q.period, subject: q.subject);
    });

final quizAnalyticsProvider = FutureProvider.autoDispose
    .family<QuizAnalytics, String>((ref, quizId) {
      return ref.watch(analyticsRepositoryProvider).quizAnalytics(quizId);
    });

final studentHistoryProvider = FutureProvider.autoDispose
    .family<List<StudentQuizResult>, String>((ref, studentId) {
      return ref.watch(analyticsRepositoryProvider).studentHistory(studentId);
    });

/// Full question list for a session (host-side view). The public, answer-key
/// stripped variant for students is fetched imperatively per index.
final sessionQuestionsProvider = FutureProvider.autoDispose
    .family<List<Question>, String>((ref, sessionId) {
      return ref.watch(sessionRepositoryProvider).sessionQuestions(sessionId);
    });

typedef PublicQuestionArg = ({String sessionId, int index});

/// Answer-key-stripped question for the student device. Re-fetches when the
/// session doc changes (new index or reveal) because the family key changes
/// and callers also invalidate on phase change.
final publicQuestionProvider = FutureProvider.autoDispose
    .family<Question?, PublicQuestionArg>((ref, arg) {
      return ref
          .watch(sessionRepositoryProvider)
          .publicQuestionAt(arg.sessionId, arg.index);
    });
