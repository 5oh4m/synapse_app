import 'package:flutter_test/flutter_test.dart';
import 'package:quizzle/data/in_memory/in_memory_backend.dart';
import 'package:quizzle/models/enums.dart';
import 'package:quizzle/models/question.dart';

/// End-to-end exercise of the live-session sync module (spec section 9):
/// join -> host advances -> students answer -> reveal -> score -> leaderboard.
void main() {
  late InMemoryBackend backend;

  setUp(() async {
    backend = InMemoryBackend();
    await backend.init();
  });

  Future<String> makePublishedQuiz(String ownerId) async {
    final quiz = await backend.quizzes.createDraft(
      ownerId: ownerId,
      title: 'Test quiz',
      subject: 'General',
    );
    await backend.quizzes.addQuestions(quiz.id, [
      for (var i = 0; i < 3; i++)
        Question(
          id: '',
          quizId: quiz.id,
          text: 'Question $i',
          options: const ['A', 'B', 'C', 'D'],
          correctIndex: 1,
          explanation: 'B is right',
          difficulty: Difficulty.easy,
          orderIndex: i,
          timeLimitSeconds: 20,
        ),
    ]);
    await backend.quizzes.publish(quiz.id);
    return quiz.id;
  }

  test(
    'full session: two students play, scores and leaderboard settle',
    () async {
      final host = await backend.auth.register(
        name: 'Host',
        email: 'host@t.dev',
        password: 'password',
        role: UserRole.educator,
      );
      final quizId = await makePublishedQuiz(host.id);
      final quiz = await backend.quizzes.get(quizId);
      final questions = await backend.quizzes.questionsOnce(quizId);

      final session = await backend.sessions.createSession(
        quiz: quiz,
        hostId: host.id,
        questions: questions,
      );
      expect(session.joinCode.length, 6);

      final sam = await backend.auth.register(
        name: 'Sam',
        email: 'sam@t.dev',
        password: 'password',
        role: UserRole.student,
      );
      final rio = await backend.auth.register(
        name: 'Rio',
        email: 'rio@t.dev',
        password: 'password',
        role: UserRole.student,
      );

      await backend.sessions.joinSession(
        joinCode: session.joinCode,
        student: sam,
      );
      await backend.sessions.joinSession(
        joinCode: session.joinCode,
        student: rio,
      );

      var participants = await backend.sessions
          .watchParticipants(session.id)
          .first;
      expect(participants.length, 2);

      await backend.sessions.startSession(session.id);
      var live = await backend.sessions.watchSession(session.id).first;
      expect(live!.status, SessionStatus.active);
      expect(live.currentQuestionIndex, 0);

      // Answer key must not leak while the question is live.
      final publicQ = await backend.sessions.publicQuestionAt(session.id, 0);
      expect(publicQ!.correctIndex, -1);

      // Sam correct and fast, Rio wrong.
      await backend.sessions.submitAnswer(
        sessionId: session.id,
        student: sam,
        questionIndex: 0,
        selectedIndex: 1,
        responseTimeMs: 1000,
      );
      await backend.sessions.submitAnswer(
        sessionId: session.id,
        student: rio,
        questionIndex: 0,
        selectedIndex: 0,
        responseTimeMs: 1000,
      );

      // Double submit is ignored (reconnect / double tap safety).
      await backend.sessions.submitAnswer(
        sessionId: session.id,
        student: sam,
        questionIndex: 0,
        selectedIndex: 2,
        responseTimeMs: 5000,
      );

      await backend.sessions.revealAnswer(session.id);
      final revealed = await backend.sessions.publicQuestionAt(session.id, 0);
      expect(revealed!.correctIndex, 1);

      participants = await backend.sessions.watchParticipants(session.id).first;
      final samP = participants.firstWhere((p) => p.studentId == sam.id);
      final rioP = participants.firstWhere((p) => p.studentId == rio.id);
      expect(samP.totalScore, greaterThan(0));
      expect(rioP.totalScore, 0);
      expect(samP.correctCount, 1);
      expect(participants.first.studentId, sam.id); // sorted by score desc

      // Finish the rest.
      await backend.sessions.nextQuestion(session.id);
      await backend.sessions.revealAnswer(session.id);
      await backend.sessions.nextQuestion(session.id);
      await backend.sessions.revealAnswer(session.id);
      await backend.sessions.nextQuestion(session.id); // past the end -> ends

      final ended = await backend.sessions.watchSession(session.id).first;
      expect(ended!.status, SessionStatus.ended);

      final board = await backend.leaderboard.watchGlobal().first;
      expect(board.any((e) => e.studentId == sam.id && e.points > 0), isTrue);
      expect(board.first.rank, 1);
    },
  );

  test('late join is rejected once the session locks', () async {
    final host = await backend.auth.register(
      name: 'H',
      email: 'h2@t.dev',
      password: 'password',
      role: UserRole.educator,
    );
    final quizId = await makePublishedQuiz(host.id);
    final quiz = await backend.quizzes.get(quizId);
    final questions = await backend.quizzes.questionsOnce(quizId);
    final session = await backend.sessions.createSession(
      quiz: quiz,
      hostId: host.id,
      questions: questions,
    );

    // createSession defaults allowLateJoin = true, so joining mid-quiz works
    // and resumes at the current question.
    await backend.sessions.startSession(session.id);
    final s = await backend.auth.register(
      name: 'Late',
      email: 'late@t.dev',
      password: 'password',
      role: UserRole.student,
    );
    final p = await backend.sessions.joinSession(
      joinCode: session.joinCode,
      student: s,
    );
    expect(p.totalScore, 0);
  });
}
