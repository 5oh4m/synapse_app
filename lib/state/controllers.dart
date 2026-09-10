import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/extraction.dart';
import '../ai/quiz_generator.dart';
import '../core/failure.dart';
import '../models/enums.dart';
import '../models/quiz.dart';
import 'providers.dart';

/// Simple busy flag shared by auth screens.
class AuthController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> _run(Future<void> Function() action) async {
    state = true;
    try {
      await action();
    } finally {
      state = false;
    }
  }

  Future<void> signIn(String email, String password) => _run(
    () => ref
        .read(authRepositoryProvider)
        .signIn(email: email, password: password),
  );

  Future<void> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) => _run(
    () => ref
        .read(authRepositoryProvider)
        .register(name: name, email: email, password: password, role: role),
  );

  /// One-tap demo login used on the sign-in screen.
  Future<void> demoAs(UserRole role) => _run(() async {
    final auth = ref.read(authRepositoryProvider);
    final email = role == UserRole.educator
        ? 'ada@quizzle.dev'
        : 'sam@quizzle.dev';
    try {
      await auth.signIn(email: email, password: 'password');
    } on AppFailure {
      await auth.register(
        name: role == UserRole.educator ? 'Demo Educator' : 'Demo Student',
        email: email,
        password: 'password',
        role: role,
      );
    }
  });

  Future<void> signOut() => _run(ref.read(authRepositoryProvider).signOut);
}

final authControllerProvider = NotifierProvider<AuthController, bool>(
  AuthController.new,
);

// ---------------------------------------------------------------------------

class GenerateParams {
  const GenerateParams({
    required this.title,
    required this.subject,
    required this.sourceType,
    required this.rawText,
    required this.pageCount,
    required this.count,
    required this.difficultyMix,
    this.fileName,
  });

  final String title;
  final String subject;
  final ContentType sourceType;
  final String rawText;
  final int pageCount;
  final int count;
  final Map<Difficulty, int> difficultyMix;
  final String? fileName;
}

/// Orchestrates the Phase 1 pipeline: ingest content -> create draft quiz ->
/// call the generator -> validate -> store as draft questions. Returns the new
/// quiz id so the caller can open the review screen.
class QuizCreationController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  Future<String> generate(GenerateParams p) async {
    state = const AsyncLoading();
    try {
      final user = ref.read(currentUserProvider);
      if (user == null) throw const AppFailure('Not signed in.');

      final content = await ref
          .read(contentRepositoryProvider)
          .ingest(
            ownerId: user.id,
            title: p.title,
            subject: p.subject,
            sourceType: p.sourceType,
            rawText: p.rawText,
            pageCount: p.pageCount,
            fileName: p.fileName,
          );
      if (content.status == ContentStatus.failed) {
        throw AppFailure(content.error ?? 'Extraction failed.');
      }

      final quiz = await ref
          .read(quizRepositoryProvider)
          .createDraft(
            ownerId: user.id,
            title: p.title.isEmpty ? 'Draft quiz' : p.title,
            subject: p.subject,
            contentItemId: content.id,
          );

      final request = GenerationRequest(
        sourceText: content.extractedText,
        count: p.count,
        difficultyMix: p.difficultyMix,
        subject: p.subject,
        title: p.title,
      );
      final questions = await ref
          .read(quizGeneratorProvider)
          .generate(request, quizId: quiz.id);

      await ref.read(quizRepositoryProvider).addQuestions(quiz.id, questions);
      state = const AsyncData(null);
      return quiz.id;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }
}

final quizCreationControllerProvider =
    NotifierProvider<QuizCreationController, AsyncValue<void>>(
      QuizCreationController.new,
    );

// ---------------------------------------------------------------------------

/// Thin wrapper over the session repo host controls, with the auto-advance
/// convenience the host screen uses.
class SessionHostController {
  SessionHostController(this.ref, this.sessionId);
  final Ref ref;
  final String sessionId;

  Future<void> start() =>
      ref.read(sessionRepositoryProvider).startSession(sessionId);
  Future<void> reveal() =>
      ref.read(sessionRepositoryProvider).revealAnswer(sessionId);
  Future<void> next() =>
      ref.read(sessionRepositoryProvider).nextQuestion(sessionId);
  Future<void> end() =>
      ref.read(sessionRepositoryProvider).endSession(sessionId);
}

final sessionHostControllerProvider = Provider.autoDispose
    .family<SessionHostController, String>(
      (ref, sessionId) => SessionHostController(ref, sessionId),
    );

// ---------------------------------------------------------------------------

final contentExtractorProvider = Provider<ContentExtractor>(
  (ref) => const ContentExtractor(),
);

/// Convenience for "go live from this quiz".
final goLiveProvider = Provider<Future<String> Function(Quiz quiz)>(
  (ref) => (quiz) async {
    final user = ref.read(currentUserProvider);
    if (user == null) throw const AppFailure('Not signed in.');
    final questions = await ref
        .read(quizRepositoryProvider)
        .questionsOnce(quiz.id);
    final session = await ref
        .read(sessionRepositoryProvider)
        .createSession(quiz: quiz, hostId: user.id, questions: questions);
    return session.id;
  },
);
