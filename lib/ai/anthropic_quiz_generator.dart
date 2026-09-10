import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/env.dart';
import '../core/failure.dart';
import '../core/ids.dart';
import '../models/enums.dart';
import '../models/question.dart';
import 'quiz_generator.dart';

/// Direct Claude call for **local development only**.
///
/// Shipping a real API key inside a client build is insecure (spec section 13).
/// In production, generation runs in the Node backend / a Cloud Function and
/// the client uses that endpoint. This class exists so a developer can iterate
/// on prompts quickly with `--dart-define=AI=anthropic --dart-define=ANTHROPIC_API_KEY=...`.
class AnthropicQuizGenerator implements QuizGenerator {
  AnthropicQuizGenerator({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.anthropic.com/v1',
              headers: {
                'x-api-key': Env.anthropicApiKey,
                'anthropic-version': '2023-06-01',
                'content-type': 'application/json',
              },
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 90),
            ),
          );

  final Dio _dio;

  static const _schemaHint = '''
Return ONLY a JSON object of the form:
{"questions":[{"question":string,"options":[string,string,string,string],
"correct_index":0-3,"explanation":string,"difficulty":"easy|medium|hard",
"source_reference":string}]}
Rules: exactly 4 options, all distinct and non-empty; correct_index in [0,3];
questions must be answerable from the provided material; no markdown, no prose
outside the JSON.''';

  @override
  Future<List<Question>> generate(
    GenerationRequest request, {
    required String quizId,
  }) async {
    final mix = request.difficultyMix.entries
        .map((e) => '${e.value}x ${e.key.name}')
        .join(', ');
    final prompt =
        '''
You are writing a multiple-choice quiz for the subject "${request.subject}".
Create exactly ${request.count} questions with roughly this difficulty mix: $mix.
Base every question strictly on this material:
"""
${_clip(request.sourceText, 24000)}
"""
$_schemaHint''';

    return _callWithRetry(prompt, quizId, request.count);
  }

  @override
  Future<Question> regenerateOne(
    GenerationRequest request, {
    required String quizId,
    required int orderIndex,
    required Difficulty difficulty,
    List<String> avoid = const [],
  }) async {
    final avoidText = avoid.isEmpty
        ? ''
        : '\nDo NOT repeat any of these questions:\n- ${avoid.join("\n- ")}';
    final prompt =
        '''
Write ONE ${difficulty.name} multiple-choice question for "${request.subject}",
answerable strictly from this material:
"""
${_clip(request.sourceText, 20000)}
"""$avoidText
$_schemaHint''';
    final list = await _callWithRetry(prompt, quizId, 1);
    return list.first.copyWith(orderIndex: orderIndex, difficulty: difficulty);
  }

  Future<List<Question>> _callWithRetry(
    String prompt,
    String quizId,
    int expected,
  ) async {
    AppFailure? last;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final raw = await _once(prompt);
        final json = _extractJson(raw);
        final parsed = parseAndValidate(
          jsonDecode(json),
          quizId: quizId,
          expectedCount: expected,
        );
        return [
          for (var i = 0; i < parsed.length; i++)
            Question(
              id: newId(),
              quizId: quizId,
              text: parsed[i].text,
              options: parsed[i].options,
              correctIndex: parsed[i].correctIndex,
              explanation: parsed[i].explanation,
              difficulty: parsed[i].difficulty,
              sourceReference: parsed[i].sourceReference,
              orderIndex: i,
              timeLimitSeconds: switch (parsed[i].difficulty) {
                Difficulty.easy => 15,
                Difficulty.medium => 20,
                Difficulty.hard => 30,
              },
            ),
        ];
      } on AppFailure catch (e) {
        last = e;
      } on DioException catch (e) {
        last = AppFailure(
          'Claude request failed (${e.response?.statusCode ?? e.type.name}).',
          cause: e,
        );
      }
    }
    throw last ?? const AppFailure('AI generation failed.');
  }

  Future<String> _once(String prompt) async {
    if (Env.anthropicApiKey.isEmpty) {
      throw const AppFailure('ANTHROPIC_API_KEY is not set.');
    }
    final res = await _dio.post<Map<String, dynamic>>(
      '/messages',
      data: {
        'model': Env.anthropicModel,
        'max_tokens': 4096,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
    );
    final content = (res.data?['content'] as List?) ?? const [];
    final buf = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text') buf.write(block['text']);
    }
    final text = buf.toString().trim();
    if (text.isEmpty) {
      throw const AppFailure('Claude returned an empty message.');
    }
    return text;
  }

  String _extractJson(String s) {
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      throw const AppFailure('No JSON object found in the AI response.');
    }
    return s.substring(start, end + 1);
  }

  String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);
}
