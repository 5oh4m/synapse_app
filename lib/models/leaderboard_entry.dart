class LeaderboardEntry {
  const LeaderboardEntry({
    required this.studentId,
    required this.displayName,
    required this.points,
    this.rank = 0,
    this.quizzesPlayed = 0,
    this.correctRate = 0,
  });

  final String studentId;
  final String displayName;
  final int points;
  final int rank;
  final int quizzesPlayed;
  final double correctRate;

  LeaderboardEntry copyWith({int? rank}) => LeaderboardEntry(
    studentId: studentId,
    displayName: displayName,
    points: points,
    rank: rank ?? this.rank,
    quizzesPlayed: quizzesPlayed,
    correctRate: correctRate,
  );

  Map<String, dynamic> toJson() => {
    'student_id': studentId,
    'display_name': displayName,
    'points': points,
    'rank': rank,
    'quizzes_played': quizzesPlayed,
    'correct_rate': correctRate,
  };

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
    studentId: (j['student_id'] ?? '') as String,
    displayName: (j['display_name'] ?? 'Player') as String,
    points: (j['points'] ?? 0) as int,
    rank: (j['rank'] ?? 0) as int,
    quizzesPlayed: (j['quizzes_played'] ?? 0) as int,
    correctRate: ((j['correct_rate'] ?? 0) as num).toDouble(),
  );
}
