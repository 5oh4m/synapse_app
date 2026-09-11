import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:quizzle/data/in_memory/in_memory_backend.dart';
import 'package:quizzle/models/enums.dart';
import 'package:quizzle/models/question.dart';

/// A registered account and everything it created should survive a full app
/// restart (simulated here by throwing away the InMemoryBackend instance and
/// constructing a brand new one, the way a page reload starts a fresh app).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('profile, quiz and score survive a simulated reload', () async {
    final first = InMemoryBackend();
    await first.init();

    final user = await first.auth.register(
      name: 'Riya',
      email: 'riya@test.dev',
      password: 'password',
      role: UserRole.educator,
    );

    final quiz = await first.quizzes.createDraft(
      ownerId: user.id,
      title: 'My quiz',
      subject: 'Math',
    );
    await first.quizzes.addQuestions(quiz.id, [
      Question(
        id: '',
        quizId: quiz.id,
        text: 'What is 2 + 2?',
        options: const ['3', '4', '5', '6'],
        correctIndex: 1,
        explanation: 'Basic arithmetic.',
        difficulty: Difficulty.easy,
        orderIndex: 0,
      ),
      Question(
        id: '',
        quizId: quiz.id,
        text: 'What is 3 + 3?',
        options: const ['5', '6', '7', '8'],
        correctIndex: 1,
        explanation: 'Basic arithmetic.',
        difficulty: Difficulty.easy,
        orderIndex: 1,
      ),
    ]);
    await first.quizzes.publish(quiz.id);

    // Persistence is debounced; give it a moment to flush to storage.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Simulate a full app restart: throw away the old instance entirely.
    final second = InMemoryBackend();
    await second.init();

    // Signed-in session is restored without re-entering credentials.
    expect(second.auth.currentUser?.email, 'riya@test.dev');
    expect(second.auth.currentUser?.name, 'Riya');

    // The quiz this account created is still there, still published.
    final quizzes = await second.quizzes.watchQuizzes(user.id).first;
    expect(quizzes.length, 1);
    expect(quizzes.single.title, 'My quiz');
    expect(quizzes.single.isPublished, isTrue);

    final questions = await second.quizzes.questionsOnce(quiz.id);
    expect(questions.length, 2);

    // A brand new account is unaffected by (and isolated from) the restored
    // data — registration still enforces unique emails against it.
    await expectLater(
      second.auth.register(
        name: 'Someone else',
        email: 'riya@test.dev',
        password: 'password',
        role: UserRole.student,
      ),
      throwsA(anything),
    );
  });

  test('signing out clears the persisted session but not the data', () async {
    final first = InMemoryBackend();
    await first.init();
    await first.auth.register(
      name: 'Jo',
      email: 'jo@test.dev',
      password: 'password',
      role: UserRole.student,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await first.auth.signOut();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final second = InMemoryBackend();
    await second.init();
    expect(second.auth.currentUser, isNull);
    // The account itself is still registered — signing back in works.
    final signedIn =
        await second.auth.signIn(email: 'jo@test.dev', password: 'password');
    expect(signedIn.name, 'Jo');
  });
}
