// Analytics, also plain SQL aggregates. Quiz analytics is owner-only; student
// history is self-only, or readable by an educator who actually hosted a
// session that student played (so a teacher cannot browse strangers).
import { Router } from 'express';
import { one, many } from '../db/pool.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound } from '../errors.js';
import { assertUuid } from '../util/validate.js';
import { ownedQuiz } from '../services/quiz.service.js';

export const analyticsRoutes = Router();

analyticsRoutes.get('/quiz/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  // 404 for a non-owner.
  const quiz = await ownedQuiz(req.params.id, req.user.sub);

  const totals = await one(
    `SELECT count(DISTINCT s.id)::int                           AS sessions_run,
            count(DISTINCT p.id)::int                           AS participants,
            COALESCE(avg(p.total_score), 0)::float              AS average_score,
            COALESCE(sum(p.answered_count), 0)::int             AS answered_total,
            COALESCE(sum(p.correct_count), 0)::int              AS correct_total
       FROM quiz_sessions s
       LEFT JOIN session_participants p ON p.session_id = s.id
      WHERE s.quiz_id = $1 AND s.status = 'ended'`,
    [quiz.id],
  );

  const attempted = await one(
    `SELECT count(*) FILTER (WHERE r.selected_index >= 0)::int AS attempted,
            count(*) FILTER (WHERE r.is_correct)::int          AS correct
       FROM responses r
       JOIN quiz_sessions s ON s.id = r.session_id
      WHERE s.quiz_id = $1 AND s.status = 'ended'`,
    [quiz.id],
  );

  // Stats key off the snapshot's source_question_id, so they survive later
  // edits to the live quiz.
  const stats = await many(
    `SELECT sq.source_question_id                                 AS question_id,
            min(sq.order_index)                                   AS order_index,
            min(sq.question_text)                                 AS text,
            count(r.id) FILTER (WHERE r.selected_index >= 0)::int AS answers,
            count(r.id) FILTER (WHERE r.is_correct)::int          AS correct,
            COALESCE(avg(r.response_time_ms) FILTER (WHERE r.selected_index >= 0), 0)::float
              AS average_time_ms
       FROM session_questions sq
       JOIN quiz_sessions s ON s.id = sq.session_id
       LEFT JOIN responses r ON r.session_question_id = sq.id
      WHERE s.quiz_id = $1 AND s.status = 'ended'
      GROUP BY sq.source_question_id
      ORDER BY order_index`,
    [quiz.id],
  );

  const questionCount = Number(quiz.question_count) || stats.length || 0;
  const completion = await one(
    `SELECT COALESCE(avg(LEAST(1.0, p.answered_count::float / NULLIF(s.total_questions, 0))), 0)::float AS rate
       FROM session_participants p
       JOIN quiz_sessions s ON s.id = p.session_id
      WHERE s.quiz_id = $1 AND s.status = 'ended'`,
    [quiz.id],
  );

  res.json({
    quiz_id: quiz.id,
    sessions_run: totals.sessions_run,
    participants: totals.participants,
    average_score: totals.average_score,
    average_correct_rate: attempted.attempted > 0 ? attempted.correct / attempted.attempted : 0,
    completion_rate: completion.rate,
    question_count: questionCount,
    question_stats: stats.map((s) => ({
      question_id: s.question_id,
      text: s.text,
      order_index: s.order_index,
      answers: s.answers,
      correct: s.correct,
      average_time_ms: Math.round(s.average_time_ms),
    })),
  });
});

analyticsRoutes.get('/student/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  const studentId = req.params.id;

  if (studentId !== req.user.sub) {
    const hosted = await one(
      `SELECT 1 FROM session_participants p
         JOIN quiz_sessions s ON s.id = p.session_id
        WHERE p.user_id = $1 AND s.host_id = $2 LIMIT 1`,
      [studentId, req.user.sub],
    );
    // Not you, and you never taught them: 404 rather than 403.
    if (!hosted) throw notFound('No history found.');
  }

  const rows = await many(
    `SELECT s.id                  AS session_id,
            s.quiz_title,
            s.ended_at,
            s.created_at,
            s.total_questions,
            z.subject,
            p.total_score,
            p.correct_count,
            (SELECT count(*) + 1 FROM session_participants o
              WHERE o.session_id = s.id
                AND (o.total_score > p.total_score
                     OR (o.total_score = p.total_score AND o.joined_at < p.joined_at)))::int AS rank
       FROM session_participants p
       JOIN quiz_sessions s ON s.id = p.session_id
       JOIN quizzes z       ON z.id = s.quiz_id
      WHERE p.user_id = $1 AND s.status = 'ended'
      ORDER BY COALESCE(s.ended_at, s.created_at) DESC
      LIMIT 200`,
    [studentId],
  );

  res.json(
    rows.map((r) => ({
      session_id: r.session_id,
      quiz_title: r.quiz_title,
      subject: r.subject,
      score: r.total_score,
      rank: r.rank,
      played_at: (r.ended_at || r.created_at).toISOString(),
      correct: r.correct_count,
      total: r.total_questions,
    })),
  );
});
