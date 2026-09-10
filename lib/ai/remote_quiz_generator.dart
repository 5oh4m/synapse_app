import 'package:dio/dio.dart';

import '../core/env.dart';
import '../core/failure.dart';
import '../core/ids.dart';
import '../models/enums.dart';
import '../models/question.dart';
import 'quiz_generator.dart';

/// Used with `BACKEND=remote`: generation runs on the Node server (which holds
/// the AI key and can do real file extraction), the client just posts the
/// request. Output is still validated here before it is shown for review.
class RemoteQuizGenerator implements QuizGenerator {
  RemoteQuizGenerator({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: Env.apiBase,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 120),
              headers: {'content-type': 'application/json'},
            ),
          );

  final Dio _dio;

  Map<String, dynamic> _payload(GenerationRequest r) => {
    'source_text': r.sourceText,
    'count': r.count,
    'subject': r.subject,
    'title': r.title,
    'difficulty_mix': {
      for (final e in r.difficultyMix.entries) e.key.name: e.value,
    },
  };

  @override
  Future<List<Question>> generate(
    GenerationRequest request, {
    required String quizId,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/generate',
        data: _payload(request)..['quiz_id'] = quizId,
      );
      final parsed = parseAndValidate(
        res.data,
        quizId: quizId,
        expectedCount: request.count,
      );
      return [
        for (var i = 0; i < parsed.length; i++) _withId(parsed[i], quizId, i),
      ];
    } on DioException catch (e) {
      throw AppFailure(_msg(e) ?? 'Generation failed on the server.', cause: e);
    }
  }

  @override
  Future<Question> regenerateOne(
    GenerationRequest request, {
    required String quizId,
    required int orderIndex,
    required Difficulty difficulty,
    List<String> avoid = const [],
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/generate',
        data: _payload(request)
          ..['quiz_id'] = quizId
          ..['count'] = 1
          ..['difficulty_mix'] = {difficulty.name: 1}
          ..['avoid'] = avoid,
      );
      final parsed = parseAndValidate(
        res.data,
        quizId: quizId,
        expectedCount: 1,
      );
      return _withId(
        parsed.first,
        quizId,
        orderIndex,
      ).copyWith(difficulty: difficulty);
    } on DioException catch (e) {
      throw AppFailure(_msg(e) ?? 'Regeneration failed.', cause: e);
    }
  }

  Question _withId(Question q, String quizId, int i) => Question(
    id: newId(),
    quizId: quizId,
    text: q.text,
    options: q.options,
    correctIndex: q.correctIndex,
    explanation: q.explanation,
    difficulty: q.difficulty,
    sourceReference: q.sourceReference,
    orderIndex: i,
    timeLimitSeconds: switch (q.difficulty) {
      Difficulty.easy => 15,
      Difficulty.medium => 20,
      Difficulty.hard => 30,
    },
  );

  String? _msg(DioException e) {
    final d = e.response?.data;
    if (d is Map && d['error'] is String) return d['error'] as String;
    return null;
  }
}
