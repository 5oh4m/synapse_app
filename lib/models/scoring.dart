/// Kahoot-style scoring, editable per quiz (spec section 9).
///
/// Correct answer: [basePoints] + a speed bonus up to [speedBonusMax] that
/// decays linearly to zero across the question's time limit.
/// Wrong or no answer: 0.
class ScoringConfig {
  const ScoringConfig({this.basePoints = 500, this.speedBonusMax = 500});

  final int basePoints;
  final int speedBonusMax;

  Map<String, dynamic> toJson() => {
    'base_points': basePoints,
    'speed_bonus_max': speedBonusMax,
  };

  factory ScoringConfig.fromJson(Map<String, dynamic>? j) => ScoringConfig(
    basePoints: (j?['base_points'] ?? 500) as int,
    speedBonusMax: (j?['speed_bonus_max'] ?? 500) as int,
  );

  int pointsFor({
    required bool isCorrect,
    required int responseTimeMs,
    required int timeLimitMs,
  }) {
    if (!isCorrect) return 0;
    if (timeLimitMs <= 0) return basePoints;
    final remaining = (timeLimitMs - responseTimeMs) / timeLimitMs;
    final frac = remaining.clamp(0.0, 1.0);
    return basePoints + (speedBonusMax * frac).round();
  }
}
