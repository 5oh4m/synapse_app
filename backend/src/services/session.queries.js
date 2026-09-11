// Read-side session queries. Lives apart from session.service.js so the
// realtime hub can build deltas without importing the service that emits them.
import { one, many } from '../db/pool.js';

export const SESSION_COLS = `
  id, quiz_id, host_id, quiz_title, join_code, status, current_question_index,
  total_questions, phase, question_started_at, question_ends_at, started_at,
  ended_at, allow_late_join, base_points, speed_bonus_max, created_at`;

export const getSession = (id) =>
  one(`SELECT ${SESSION_COLS} FROM quiz_sessions WHERE id = $1`, [id]);

export const getSessionByCode = (code) =>
  one(`SELECT ${SESSION_COLS} FROM quiz_sessions WHERE join_code = $1`, [String(code).toUpperCase()]);

/**
 * Session plus the caller's relationship to it. Returns null when the session
 * does not exist, so callers can 404 without a second round trip.
 */
export async function getSessionAccess(sessionId, userId) {
  const row = await one(
    `SELECT s.id, s.quiz_id, s.host_id, s.quiz_title, s.join_code, s.status,
            s.current_question_index, s.total_questions, s.phase,
            s.question_started_at, s.question_ends_at, s.started_at, s.ended_at,
            s.allow_late_join, s.base_points, s.speed_bonus_max, s.created_at,
            p.id AS participant_id, p.display_name AS participant_name
       FROM quiz_sessions s
       LEFT JOIN session_participants p ON p.session_id = s.id AND p.user_id = $2
      WHERE s.id = $1`,
    [sessionId, userId],
  );
  if (!row) return null;
  return {
    session: row,
    isHost: row.host_id === userId,
    participantId: row.participant_id || null,
    participantName: row.participant_name || null,
  };
}

export const listParticipants = (sessionId) =>
  many(
    `SELECT id, session_id, user_id, display_name, total_score, correct_count,
            answered_count, streak, connected, joined_at,
            COALESCE((SELECT max(question_index) FROM responses r WHERE r.participant_id = p.id), -1)
              AS last_answered_index
       FROM session_participants p
      WHERE session_id = $1
      ORDER BY total_score DESC, joined_at ASC`,
    [sessionId],
  );

export const listSessionQuestions = (sessionId) =>
  many(
    `SELECT id, session_id, order_index, question_text, options, correct_index,
            explanation, difficulty, source_reference, time_limit_seconds
       FROM session_questions WHERE session_id = $1 ORDER BY order_index`,
    [sessionId],
  );

export const getSessionQuestion = (sessionId, index) =>
  one(
    `SELECT id, session_id, order_index, question_text, options, correct_index,
            explanation, difficulty, source_reference, time_limit_seconds
       FROM session_questions WHERE session_id = $1 AND order_index = $2`,
    [sessionId, index],
  );

/** {answered, total} for the answer.count delta — counts only, no identities. */
export async function answerCounts(sessionId, questionIndex) {
  const row = await one(
    `SELECT (SELECT count(*) FROM session_participants WHERE session_id = $1) AS total,
            (SELECT count(*) FROM responses
              WHERE session_id = $1 AND question_index = $2 AND selected_index >= 0) AS answered`,
    [sessionId, questionIndex],
  );
  return { answered: row?.answered ?? 0, total: row?.total ?? 0 };
}

/** [n,n,n,n] choice histogram for one question. */
export async function distribution(sessionId, questionIndex) {
  const rows = await many(
    `SELECT selected_index, count(*) AS n
       FROM responses
      WHERE session_id = $1 AND question_index = $2 AND selected_index BETWEEN 0 AND 3
      GROUP BY selected_index`,
    [sessionId, questionIndex],
  );
  const out = [0, 0, 0, 0];
  for (const r of rows) out[r.selected_index] = Number(r.n);
  return out;
}

export async function scoreboard(sessionId) {
  const rows = await many(
    `SELECT id AS participant_id, display_name, total_score, correct_count, answered_count
       FROM session_participants
      WHERE session_id = $1
      ORDER BY total_score DESC, joined_at ASC`,
    [sessionId],
  );
  return rows.map((r, i) => ({ ...r, rank: i + 1 }));
}

export const listResponses = (sessionId) =>
  many(
    `SELECT r.*, p.user_id
       FROM responses r JOIN session_participants p ON p.id = r.participant_id
      WHERE r.session_id = $1
      ORDER BY r.question_index, r.answered_at`,
    [sessionId],
  );
