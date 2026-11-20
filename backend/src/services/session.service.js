// Session lifecycle, scoring, and the auto-reveal timer.
//
// Defects fixed here:
//  - Client-dictated response times. The old handler trusted
//    `body.response_time_ms`, so a student could post 1 and take the full speed
//    bonus every time. Elapsed is now `now() - question_started_at`, read
//    inside the same transaction that writes the response. Any timing field in
//    the body is rejected by the route before this is reached.
//  - Answering as somebody else. The participant row is looked up from the JWT
//    subject; `student_id` in a body is rejected.
//  - Rescoring on double submit. UNIQUE (participant_id, question_index) plus
//    ON CONFLICT DO NOTHING means the second submit returns the first row.
import crypto from 'node:crypto';
import { withTransaction, many, one, UNIQUE_VIOLATION } from '../db/pool.js';
import { config } from '../config.js';
import { log } from '../log.js';
import { conflict, notFound, validation } from '../errors.js';
import {
  SESSION_COLS,
  getSession,
  getSessionQuestion,
  distribution,
  scoreboard,
  listSessionQuestions,
  answersForQuestion,
  isRevealed,
} from './session.queries.js';
import { answerResultJson } from '../util/serialize.js';
import * as hub from '../realtime/hub.js';

// Visually unambiguous alphabet: no I/O/0/1.
const JOIN_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const makeJoinCode = (n = 6) =>
  Array.from({ length: n }, () => JOIN_ALPHABET[crypto.randomInt(JOIN_ALPHABET.length)]).join('');

/**
 * Points for one answer.
 *   correct -> base + round(speed_bonus_max * (1 - elapsed/limit))
 *   wrong or timed out -> 0
 * Clamped so a late-but-graced answer cannot go negative.
 */
export function pointsFor({ basePoints, speedBonusMax }, isCorrect, elapsedMs, limitMs) {
  if (!isCorrect) return 0;
  if (limitMs <= 0) return basePoints;
  const remaining = Math.min(1, Math.max(0, 1 - elapsedMs / limitMs));
  return Math.max(0, basePoints + Math.round(speedBonusMax * remaining));
}

// ---------------------------------------------------------------- create -----

export async function createSession({ quizId, hostId }) {
  return withTransaction(async (client) => {
    const { rows: quizRows } = await client.query(
      `SELECT id, owner_id, title, base_points, speed_bonus_max
         FROM quizzes WHERE id = $1 AND owner_id = $2`,
      [quizId, hostId],
    );
    // Not the owner -> 404, so the endpoint does not confirm the quiz exists.
    if (!quizRows[0]) throw notFound('Quiz not found.');
    const quiz = quizRows[0];

    const { rows: questions } = await client.query(
      `SELECT id, question_text, options, correct_index, explanation, difficulty,
              source_reference, order_index, time_limit_seconds
         FROM questions WHERE quiz_id = $1 ORDER BY order_index`,
      [quiz.id],
    );
    if (questions.length === 0) throw conflict('This quiz has no questions yet.');

    // Retry on the (vanishingly unlikely) join-code collision. A failed INSERT
    // aborts the transaction, so each attempt runs inside its own savepoint.
    let session = null;
    for (let attempt = 0; attempt < 8 && !session; attempt += 1) {
      await client.query('SAVEPOINT try_join_code');
      try {
        const { rows } = await client.query(
          `INSERT INTO quiz_sessions
             (quiz_id, host_id, quiz_title, join_code, total_questions, base_points, speed_bonus_max)
           VALUES ($1, $2, $3, $4, $5, $6, $7)
           RETURNING ${SESSION_COLS}`,
          [
            quiz.id,
            hostId,
            quiz.title,
            makeJoinCode(),
            questions.length,
            quiz.base_points,
            quiz.speed_bonus_max,
          ],
        );
        session = rows[0];
        await client.query('RELEASE SAVEPOINT try_join_code');
      } catch (err) {
        await client.query('ROLLBACK TO SAVEPOINT try_join_code');
        if (err.code !== UNIQUE_VIOLATION) throw err;
      }
    }
    if (!session) throw conflict('Could not allocate a join code. Try again.');

    // Freeze the questions: editing the quiz mid-game cannot change play.
    for (const q of questions) {
      await client.query(
        `INSERT INTO session_questions
           (session_id, source_question_id, order_index, question_text, options,
            correct_index, explanation, difficulty, source_reference, time_limit_seconds)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
        [
          session.id,
          q.id,
          q.order_index,
          q.question_text,
          JSON.stringify(q.options),
          q.correct_index,
          q.explanation,
          q.difficulty,
          q.source_reference,
          q.time_limit_seconds,
        ],
      );
    }
    return session;
  });
}

// ------------------------------------------------------------------ join -----

export async function joinSession({ joinCode, user }) {
  const result = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT ${SESSION_COLS} FROM quiz_sessions
        WHERE join_code = $1 AND status <> 'ended' FOR UPDATE`,
      [String(joinCode).toUpperCase()],
    );
    const session = rows[0];
    if (!session) throw notFound('No live session with that code.');

    const existing = await client.query(
      'SELECT * FROM session_participants WHERE session_id = $1 AND user_id = $2',
      [session.id, user.sub],
    );
    if (existing.rows[0]) {
      // Idempotent rejoin: keep the score. Presence is the socket's business
      // (realtime/hub.js), not this request's.
      return { session, participant: existing.rows[0], created: false };
    }
    if (session.status !== 'lobby' && !session.allow_late_join) {
      throw conflict('This session has already started.');
    }
    const { rows: ins } = await client.query(
      `INSERT INTO session_participants (session_id, user_id, display_name)
       VALUES ($1, $2, $3) RETURNING *`,
      [session.id, user.sub, user.name || 'Player'],
    );
    return { session, participant: ins[0], created: true };
  });

  // Only a new player is news. A re-join used to push the full scoreboard to
  // every device in the room, so a lobby of flaky phones was a steady stream of
  // roster frames. The joining device already has its own row from the response.
  if (result.created) hub.emitParticipantJoined(result.session.id, result.participant);
  return result;
}

export async function setConnected({ sessionId, userId, connected }) {
  const row = await one(
    `UPDATE session_participants SET connected = $3
      WHERE session_id = $1 AND user_id = $2 RETURNING *`,
    [sessionId, userId, !!connected],
  );
  if (!row) throw notFound('You are not in that session.');
  return row;
}

// --------------------------------------------------------------- control -----

/** Moves a session onto `index` and starts its clock. Host-authorized upstream. */
async function advanceTo(client, session, index) {
  const { rows: qrows } = await client.query(
    'SELECT time_limit_seconds FROM session_questions WHERE session_id = $1 AND order_index = $2',
    [session.id, index],
  );
  if (!qrows[0]) throw conflict('That question is not in this session.');
  const limit = qrows[0].time_limit_seconds;
  const { rows } = await client.query(
    `UPDATE quiz_sessions
        SET status = 'active',
            current_question_index = $2,
            phase = 'asking',
            revealed_at = NULL,
            question_started_at = now(),
            question_ends_at = now() + make_interval(secs => $3::int),
            started_at = COALESCE(started_at, now())
      WHERE id = $1
      RETURNING ${SESSION_COLS}`,
    [session.id, index, limit],
  );
  return rows[0];
}

export async function startSession(sessionId) {
  const session = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT ${SESSION_COLS} FROM quiz_sessions WHERE id = $1 FOR UPDATE`,
      [sessionId],
    );
    const s = rows[0];
    if (!s) throw notFound('Session not found.');
    if (s.status === 'ended') throw conflict('This session has already ended.');
    if (s.status === 'active') return s; // idempotent
    if (s.total_questions === 0) throw conflict('This session has no questions.');
    return advanceTo(client, s, 0);
  });
  hub.emitSessionState(session);
  return session;
}

/**
 * Reveal: freeze answers, zero-fill anybody who did not answer (so the
 * distribution and the answered counts are complete), publish the key.
 * Used by the host button and by the auto-reveal timer.
 */
export async function revealCurrent(sessionId, { reason = 'host' } = {}) {
  const out = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT ${SESSION_COLS} FROM quiz_sessions WHERE id = $1 FOR UPDATE`,
      [sessionId],
    );
    const s = rows[0];
    if (!s) throw notFound('Session not found.');
    if (s.status !== 'active') throw conflict('This session is not running a question.');
    if (s.phase === 'revealing') return { session: s, changed: false };

    await zeroFillMissing(client, s);

    const { rows: upd } = await client.query(
      `UPDATE quiz_sessions SET phase = 'revealing', revealed_at = now() WHERE id = $1 RETURNING ${SESSION_COLS}`,
      [sessionId],
    );
    return { session: upd[0], changed: true };
  });

  if (out.changed) {
    await publishReveal(out.session, reason);
  }
  return out.session;
}

/** Emits the reveal + scoreboard deltas for the session's current question. */
async function publishReveal(session, reason) {
  const q = await getSessionQuestion(session.id, session.current_question_index);
  hub.emitSessionState(session);
  if (q) {
    hub.emitQuestionRevealed(session.id, {
      question_index: session.current_question_index,
      correct_index: q.correct_index,
      explanation: q.explanation ?? '',
      distribution: await distribution(session.id, session.current_question_index),
      reason,
    });
    // Each player's own outcome, to that player's sockets only. The answer
    // route no longer returns correctness, so this is where it arrives.
    const rows = await answersForQuestion(session.id, session.current_question_index);
    const byUser = new Map(rows.map((r) => [r.user_id, answerResultJson(r)]));
    hub.emitToEachUser(session.id, 'answer.result', (userId) => byUser.get(userId) ?? null);
  }
  hub.emitScoreboard(session.id, await scoreboard(session.id));
}

/**
 * Everyone who did not answer the current question gets a 0-point,
 * selected_index = -1 row. ON CONFLICT guards against racing a real answer.
 */
async function zeroFillMissing(client, session) {
  const idx = session.current_question_index;
  if (idx < 0) return;
  const { rows: qrows } = await client.query(
    'SELECT id, time_limit_seconds FROM session_questions WHERE session_id = $1 AND order_index = $2',
    [session.id, idx],
  );
  if (!qrows[0]) return;
  await client.query(
    `INSERT INTO responses
       (session_id, participant_id, session_question_id, question_index,
        selected_index, is_correct, response_time_ms, points_awarded)
     SELECT $1, p.id, $2, $3, -1, false, $4, 0
       FROM session_participants p
      WHERE p.session_id = $1
        AND NOT EXISTS (
          SELECT 1 FROM responses r
           WHERE r.participant_id = p.id AND r.question_index = $3)
     ON CONFLICT (participant_id, question_index) DO NOTHING`,
    [session.id, qrows[0].id, idx, qrows[0].time_limit_seconds * 1000],
  );
  // Keep the denormalised counters on session_participants honest.
  await client.query(
    `UPDATE session_participants p
        SET answered_count = agg.n, streak = CASE WHEN agg.last_correct THEN p.streak ELSE 0 END
       FROM (
         SELECT participant_id, count(*) AS n,
                bool_and(is_correct) FILTER (WHERE question_index = $2) AS last_correct
           FROM responses WHERE session_id = $1 GROUP BY participant_id
       ) agg
      WHERE p.id = agg.participant_id`,
    [session.id, idx],
  );
}

export async function nextQuestion(sessionId) {
  const out = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT ${SESSION_COLS} FROM quiz_sessions WHERE id = $1 FOR UPDATE`,
      [sessionId],
    );
    const s = rows[0];
    if (!s) throw notFound('Session not found.');
    if (s.status === 'ended') return { session: s, ended: true };
    if (s.status === 'lobby') throw conflict('Start the session first.');

    // Anybody who never answered the question we are leaving scores 0 for it.
    if (s.phase === 'asking') await zeroFillMissing(client, s);

    const next = s.current_question_index + 1;
    if (next >= s.total_questions) {
      return { session: await endInTransaction(client, s), ended: true };
    }
    return { session: await advanceTo(client, s, next), ended: false };
  });

  if (out.ended) {
    await publishEnd(out.session);
  } else {
    hub.emitSessionState(out.session);
  }
  return out.session;
}

async function endInTransaction(client, session) {
  if (session.status === 'ended') return session;
  if (session.status === 'active') await zeroFillMissing(client, session);
  const { rows } = await client.query(
    `UPDATE quiz_sessions
        SET status = 'ended', phase = 'revealing', revealed_at = NULL, ended_at = now()
      WHERE id = $1 RETURNING ${SESSION_COLS}`,
    [session.id],
  );
  return rows[0];
}

export async function endSession(sessionId) {
  const session = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT ${SESSION_COLS} FROM quiz_sessions WHERE id = $1 FOR UPDATE`,
      [sessionId],
    );
    if (!rows[0]) throw notFound('Session not found.');
    return endInTransaction(client, rows[0]);
  });
  await publishEnd(session);
  return session;
}

async function publishEnd(session) {
  const board = await scoreboard(session.id);
  hub.emitSessionState(session);
  hub.emitScoreboard(session.id, board);
  hub.emitSessionEnded(session.id, {
    session_id: session.id,
    quiz_title: session.quiz_title,
    ended_at: session.ended_at,
    total_questions: session.total_questions,
    scoreboard: board,
  });
}

// ---------------------------------------------------------------- answer -----

/**
 * Scores one answer. `userId` comes from the JWT. Elapsed time is measured by
 * Postgres against question_started_at inside the write transaction, so no
 * client clock or client-supplied duration can influence the score.
 */
export async function submitAnswer({ sessionId, userId, selectedIndex, clientQuestionIndex }) {
  const out = await withTransaction(async (client) => {
    const { rows: srows } = await client.query(
      `SELECT ${SESSION_COLS},
              EXTRACT(EPOCH FROM (now() - question_started_at)) * 1000 AS elapsed_ms,
              (now() > question_ends_at + make_interval(secs => $2::float)) AS past_deadline
         FROM quiz_sessions WHERE id = $1 FOR UPDATE`,
      [sessionId, config.answerGraceMs / 1000],
    );
    const session = srows[0];
    if (!session) throw notFound('Session not found.');

    const { rows: prows } = await client.query(
      'SELECT * FROM session_participants WHERE session_id = $1 AND user_id = $2',
      [sessionId, userId],
    );
    const participant = prows[0];
    if (!participant) throw notFound('Join the session before answering.');

    const idx = session.current_question_index;

    // A prior row wins outright: same result, 200, no rescore. Checked before
    // the phase guard so a resubmit after reveal still returns the original.
    const prior = await client.query(
      `SELECT r.*, p.user_id FROM responses r
         JOIN session_participants p ON p.id = r.participant_id
        WHERE r.participant_id = $1 AND r.question_index = $2`,
      [participant.id, clientQuestionIndex ?? idx],
    );
    if (prior.rows[0]) return { response: prior.rows[0], scored: false, session };

    if (session.status !== 'active' || session.phase !== 'asking') {
      throw conflict('That question is not accepting answers.');
    }
    if (clientQuestionIndex !== undefined && clientQuestionIndex !== idx) {
      throw conflict('That question is no longer the current one.');
    }
    if (session.past_deadline) throw conflict("Time is up for this question.");

    const { rows: qrows } = await client.query(
      'SELECT * FROM session_questions WHERE session_id = $1 AND order_index = $2',
      [sessionId, idx],
    );
    const question = qrows[0];
    if (!question) throw conflict('That question is not in this session.');

    const limitMs = question.time_limit_seconds * 1000;
    // Server-measured. `elapsed_ms` came from Postgres, not the request.
    const elapsedMs = Math.min(Math.max(0, Math.round(Number(session.elapsed_ms) || 0)), limitMs);
    const isCorrect = selectedIndex >= 0 && selectedIndex === question.correct_index;
    const points = pointsFor(
      { basePoints: session.base_points, speedBonusMax: session.speed_bonus_max },
      isCorrect,
      elapsedMs,
      limitMs,
    );

    const { rows: ins } = await client.query(
      `INSERT INTO responses
         (session_id, participant_id, session_question_id, question_index,
          selected_index, is_correct, response_time_ms, points_awarded)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
       ON CONFLICT (participant_id, question_index) DO NOTHING
       RETURNING *`,
      [sessionId, participant.id, question.id, idx, selectedIndex, isCorrect, elapsedMs, points],
    );

    if (!ins[0]) {
      // Lost a race with a concurrent submit: return that one, do not rescore.
      const { rows: winner } = await client.query(
        'SELECT * FROM responses WHERE participant_id = $1 AND question_index = $2',
        [participant.id, idx],
      );
      return { response: winner[0], scored: false, session };
    }

    const { rows: pupd } = await client.query(
      `UPDATE session_participants
          SET total_score = total_score + $2,
              correct_count = correct_count + $3,
              answered_count = answered_count + 1,
              streak = CASE WHEN $4 THEN streak + 1 ELSE 0 END
        WHERE id = $1 RETURNING *`,
      [participant.id, points, isCorrect ? 1 : 0, isCorrect],
    );

    return { response: { ...ins[0], user_id: userId }, scored: true, session, participant: pupd[0] };
  });

  if (out.scored) {
    // Counts only, coalesced on the hub's 250 ms tick.
    hub.queueAnswerCount(sessionId);
  }
  return out;
}

// ----------------------------------------------------------- auto reveal -----

let autoRevealTimer = null;

/**
 * One process-wide timer. A host who closes their laptop no longer freezes the
 * class: the server reveals when question_ends_at passes.
 */
export function startAutoRevealTimer() {
  if (autoRevealTimer) return autoRevealTimer;
  autoRevealTimer = setInterval(() => {
    tickAutoReveal().catch((err) => log.warn('auto-reveal tick failed', { message: err.message }));
  }, config.autoRevealTickMs);
  autoRevealTimer.unref?.();
  return autoRevealTimer;
}

export function stopAutoRevealTimer() {
  if (autoRevealTimer) clearInterval(autoRevealTimer);
  autoRevealTimer = null;
}

export async function tickAutoReveal() {
  const due = await many(
    `SELECT id FROM quiz_sessions
      WHERE status = 'active' AND phase = 'asking'
        AND question_ends_at IS NOT NULL
        AND question_ends_at + make_interval(secs => $1::float) <= now()
      LIMIT 50`,
    [config.answerGraceMs / 1000],
  );
  for (const row of due) {
    try {
      await revealCurrent(row.id, { reason: 'timeout' });
    } catch (err) {
      // CONFLICT just means the host revealed first; anything else is worth a line.
      if (err.code !== 'CONFLICT' && err.code !== 'NOT_FOUND') {
        log.warn('auto-reveal failed', { session_id: row.id, message: err.message });
      }
    }
  }
  await tickAutoAdvance();
  return due.length;
}

export async function tickAutoAdvance() {
  const due = await many(
    `SELECT id FROM quiz_sessions
      WHERE status = 'active' AND phase = 'revealing'
        AND revealed_at IS NOT NULL
        AND revealed_at + make_interval(secs => $1::float) <= now()
      LIMIT 50`,
    [config.autoAdvanceSeconds || 5],
  );
  for (const row of due) {
    try {
      await nextQuestion(row.id);
    } catch (err) {
      if (err.code !== 'CONFLICT' && err.code !== 'NOT_FOUND') {
        log.warn('auto-advance failed', { session_id: row.id, message: err.message });
      }
    }
  }
  return due.length;
}

// --------------------------------------------------------------- results -----

export async function sessionResults({ sessionId, participantId }) {
  const session = await getSession(sessionId);
  if (!session) throw notFound('Session not found.');
  const board = await scoreboard(sessionId);
  const questions = await listSessionQuestions(sessionId);

  let breakdown = null;
  if (participantId) {
    const rows = await many(
      `SELECT question_index, selected_index, is_correct, response_time_ms, points_awarded, answered_at
         FROM responses WHERE participant_id = $1 ORDER BY question_index`,
      [participantId],
    );
    const byIndex = new Map(rows.map((r) => [r.question_index, r]));
    // Only questions the class has already seen answered. This endpoint used to
    // return correct_index and the explanation for every question, mid-quiz.
    breakdown = questions.filter((q) => isRevealed(session, q.order_index)).map((q) => {
      const r = byIndex.get(q.order_index) || null;
      return {
        question_index: q.order_index,
        question_text: q.question_text,
        options: q.options,
        correct_index: q.correct_index,
        explanation: q.explanation ?? '',
        // Revealed only once the session is over or that question has passed.
        selected_index: r ? r.selected_index : null,
        is_correct: r ? r.is_correct : false,
        response_time_ms: r ? r.response_time_ms : null,
        points_awarded: r ? r.points_awarded : 0,
      };
    });
  }

  const totals = await one(
    `SELECT count(*)::int AS responses,
            count(*) FILTER (WHERE is_correct)::int AS correct,
            count(*) FILTER (WHERE selected_index >= 0)::int AS attempted
       FROM responses WHERE session_id = $1`,
    [sessionId],
  );

  return {
    session,
    scoreboard: board,
    totals,
    my_participant_id: participantId,
    my_breakdown: breakdown,
  };
}

/**
 * docs/API.md: "`response_time_ms` from a client is ignored entirely."
 *
 * Deleting the keys here means no code path downstream can read one even by
 * accident — the value never reaches submitAnswer, which measures elapsed time
 * in Postgres. Returns the names it dropped so the route can say so in the
 * response rather than leaving the client guessing why its number vanished.
 */
export function stripClientTiming(body) {
  const dropped = [];
  if (!body || typeof body !== 'object') return dropped;
  for (const f of ['response_time_ms', 'responseTimeMs', 'elapsed_ms', 'answered_at', 'points_awarded', 'is_correct']) {
    if (f in body) {
      delete body[f];
      dropped.push(f);
    }
  }
  return dropped;
}

export function requireSelectedIndex(body) {
  const v = body?.selected_index;
  if (!Number.isInteger(v) || v < -1 || v > 3) {
    throw validation('selected_index must be -1 (skipped) or 0..3.', 'selected_index');
  }
  return v;
}
