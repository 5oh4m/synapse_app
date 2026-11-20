import '../core/failure.dart';
import '../data/remote/api_client.dart';
import '../models/enums.dart';
import '../models/question.dart';
import 'quiz_generator.dart';

/// `POST /generate` on the backend.
///
/// Generation lives on the server because that is where the model key, the
/// 20/hour rate limit and the retry/parse hardening are. The client never
/// holds an AI key: a `--dart-define` is a compile-time constant that ends up
/// readable inside `main.dart.js`.
///
/// Output is still validated here before it is shown for review, so a bad
/// payload cannot reach the editor.
class RemoteQuizGenerator implements QuizGenerator {
  RemoteQuizGenerator(this._api);

  final ApiClient _api;

  Map<String, dynamic> _payload(GenerationRequest r) => {
    if (r.contentId != null) 'content_id': r.contentId,
    if (r.contentId == null) 'source_text': r.sourceText,
    'count': r.count,
    if (r.subject.isNotEmpty) 'subject': r.subject,
    'difficulty_mix': {
      for (final e in r.difficultyMix.entries)
        if (e.value > 0) e.key.name: e.value,
    },
  };

  @override
  Future<List<Question>> generate(
    GenerationRequest request, {
    required String quizId,
  }) async {
    final res = await _api.post('/generate', body: _payload(request));
    final parsed = parseAndValidate(
      res,
      quizId: quizId,
      expectedCount: request.count,
    );
    return [
      for (var i = 0; i < parsed.length; i++) _timed(parsed[i], orderIndex: i),
    ];
  }

  @override
  Future<Question> regenerateOne(
    GenerationRequest request, {
    required String quizId,
    required int orderIndex,
    required Difficulty difficulty,
    List<String> avoid = const [],
    String? questionId,
  }) async {
    final res = await _api.post(
      '/generate',
      body: _payload(request)
        ..['count'] = 1
        ..['difficulty_mix'] = {difficulty.name: 1},
    );
    final parsed = parseAndValidate(res, quizId: quizId, expectedCount: 1);
    // The server has no "avoid" parameter; picking the first result that is not
    // already on the quiz is done here rather than pretended about there.
    final avoidSet = avoid.map(_normalize).toSet();
    final pick = parsed.firstWhere(
      (q) => !avoidSet.contains(_normalize(q.text)),
      orElse: () => parsed.first,
    );
    final timed = _timed(
      pick,
      orderIndex: orderIndex,
    ).copyWith(difficulty: difficulty);
    // With an id the caller can PUT it straight over the existing row.
    return questionId == null ? timed : timed.withId(questionId);
  }

  String _normalize(String s) => s.trim().toLowerCase();

  Question _timed(Question q, {required int orderIndex}) => q
      .copyWith(
        orderIndex: orderIndex,
        timeLimitSeconds: q.timeLimitSeconds > 0
            ? q.timeLimitSeconds
            : switch (q.difficulty) {
                Difficulty.easy => 15,
                Difficulty.medium => 20,
                Difficulty.hard => 30,
              },
      )
      .withId('', quizId: q.quizId, orderIndex: orderIndex);

  /// Surfaces the server's reason verbatim (rate limit, upstream parse
  /// failure, "not enough source text") rather than a generic message.
  static AppFailure describe(Object error) => error is AppFailure
      ? error
      : AppFailure('Generation failed: $error', code: 'UPSTREAM');
}
