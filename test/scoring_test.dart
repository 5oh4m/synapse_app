import 'package:flutter_test/flutter_test.dart';
import 'package:quizzle/models/scoring.dart';

void main() {
  group('ScoringConfig.pointsFor', () {
    const s = ScoringConfig(basePoints: 500, speedBonusMax: 500);

    test('wrong answer scores zero', () {
      expect(
        s.pointsFor(isCorrect: false, responseTimeMs: 10, timeLimitMs: 20000),
        0,
      );
    });

    test('instant correct answer gets full base + full speed bonus', () {
      expect(
        s.pointsFor(isCorrect: true, responseTimeMs: 0, timeLimitMs: 20000),
        1000,
      );
    });

    test('answer at the buzzer keeps base but loses the speed bonus', () {
      expect(
        s.pointsFor(isCorrect: true, responseTimeMs: 20000, timeLimitMs: 20000),
        500,
      );
    });

    test('halfway through the window gives half the bonus', () {
      expect(
        s.pointsFor(isCorrect: true, responseTimeMs: 10000, timeLimitMs: 20000),
        750,
      );
    });

    test('overtime never goes below base and never negative', () {
      final p = s.pointsFor(
        isCorrect: true,
        responseTimeMs: 999999,
        timeLimitMs: 20000,
      );
      expect(p, 500);
    });
  });
}
