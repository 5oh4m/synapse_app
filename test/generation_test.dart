import 'package:flutter_test/flutter_test.dart';
import 'package:quizzle/ai/mock_quiz_generator.dart';
import 'package:quizzle/ai/quiz_generator.dart';
import 'package:quizzle/core/failure.dart';
import 'package:quizzle/models/enums.dart';

void main() {
  test(
    'mock generator returns the requested count of valid questions',
    () async {
      final gen = MockQuizGenerator();
      final questions = await gen.generate(
        const GenerationRequest(
          sourceText:
              'Photosynthesis converts light energy into chemical energy stored '
              'in glucose. Chlorophyll absorbs mostly red and blue light. The '
              'light dependent reactions occur in the thylakoid membranes. The '
              'Calvin cycle fixes carbon dioxide into sugars in the stroma.',
          count: 6,
          difficultyMix: {
            Difficulty.easy: 2,
            Difficulty.medium: 3,
            Difficulty.hard: 1,
          },
          subject: 'Biology',
        ),
        quizId: 'quiz-1',
      );
      expect(questions.length, 6);
      for (final q in questions) {
        expect(q.isValid(), isTrue, reason: q.text);
        expect(q.options.length, 4);
        expect(q.correctIndex, inInclusiveRange(0, 3));
        expect(q.quizId, 'quiz-1');
      }
    },
  );

  group('parseAndValidate', () {
    test('accepts a well formed payload', () {
      final out = parseAndValidate(
        [
          {
            'question': 'Q?',
            'options': ['a', 'b', 'c', 'd'],
            'correct_index': 2,
            'explanation': 'because',
            'difficulty': 'easy',
          },
        ],
        quizId: 'q',
        expectedCount: 1,
      );
      expect(out.single.correctIndex, 2);
    });

    test('rejects the wrong number of options', () {
      expect(
        () => parseAndValidate(
          [
            {
              'question': 'Q?',
              'options': ['a', 'b', 'c'],
              'correct_index': 0,
            },
          ],
          quizId: 'q',
          expectedCount: 1,
        ),
        throwsA(isA<AppFailure>()),
      );
    });

    test('rejects an out of range correct_index', () {
      expect(
        () => parseAndValidate(
          [
            {
              'question': 'Q?',
              'options': ['a', 'b', 'c', 'd'],
              'correct_index': 9,
            },
          ],
          quizId: 'q',
          expectedCount: 1,
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  });
}
