// Quiz + question persistence, with ownership enforced on every mutation.
//
// Defects fixed:
//  - IDOR. DELETE/PUT /quizzes/:id and publish/unpublish had no auth at all.
//    Every statement here carries `AND owner_id = $n`, and a miss raises 404 so
//    the endpoint does not confirm that somebody else's quiz exists.
//  - "Regenerate" duplicating a question. replaceQuestion UPDATEs in place,
//    keeping both the id and the order_index; the UNIQUE (quiz_id, order_index)
//    constraint makes a duplicate impossible even if a caller tried.
import { one, many, withTransaction, query } from '../db/pool.js';
import { notFound, conflict, validation } from '../errors.js';
import { validateQuestion } from '../util/validate.js';

export const QUIZ_COLS = `q.id, q.owner_id, q.title, q.subject, q.description, q.content_id,
  q.status, q.base_points, q.speed_bonus_max, q.created_at, q.updated_at,
  (SELECT count(*) FROM questions qq WHERE qq.quiz_id = q.id) AS question_count`;

export const QUESTION_COLS =
  'id, quiz_id, question_text, options, correct_index, explanation, difficulty, source_reference, order_index, time_limit_seconds';

/** Owner-only read. Wrong owner or missing -> 404. */
export async function ownedQuiz(quizId, ownerId) {
  const row = await one(
    `SELECT ${QUIZ_COLS} FROM quizzes q WHERE q.id = $1 AND q.owner_id = $2`,
    [quizId, ownerId],
  );
  if (!row) throw notFound('Quiz not found.');
  return row;
}

/** Readable by its owner, or by anyone once published. */
export async function readableQuiz(quizId, userId) {
  const row = await one(
    `SELECT ${QUIZ_COLS} FROM quizzes q
      WHERE q.id = $1 AND (q.owner_id = $2 OR q.status = 'published')`,
    [quizId, userId],
  );
  if (!row) throw notFound('Quiz not found.');
  return row;
}

export const listQuizzes = (ownerId) =>
  many(`SELECT ${QUIZ_COLS} FROM quizzes q WHERE q.owner_id = $1 ORDER BY q.created_at DESC`, [
    ownerId,
  ]);

export const listPublished = () =>
  many(`SELECT ${QUIZ_COLS} FROM quizzes q WHERE q.status = 'published' ORDER BY q.created_at DESC`);

export async function createQuiz({ ownerId, title, subject, description, contentId }) {
  if (contentId) {
    // Referencing somebody else's library item is not allowed.
    const owned = await one('SELECT id FROM content_items WHERE id = $1 AND owner_id = $2', [
      contentId,
      ownerId,
    ]);
    if (!owned) throw notFound('Content not found.');
  }
  return one(
    `WITH ins AS (
       INSERT INTO quizzes (owner_id, title, subject, description, content_id)
       VALUES ($1,$2,$3,$4,$5) RETURNING *
     )
     SELECT ${QUIZ_COLS} FROM ins q`,
    [ownerId, title, subject ?? null, description ?? '', contentId ?? null],
  );
}

export async function patchQuiz(quizId, ownerId, patch) {
  await ownedQuiz(quizId, ownerId);
  const row = await one(
    `WITH upd AS (
       UPDATE quizzes SET
         title           = COALESCE($3, title),
         subject         = COALESCE($4, subject),
         description     = COALESCE($5, description),
         base_points     = COALESCE($6, base_points),
         speed_bonus_max = COALESCE($7, speed_bonus_max),
         updated_at      = now()
       WHERE id = $1 AND owner_id = $2
       RETURNING *
     )
     SELECT ${QUIZ_COLS} FROM upd q`,
    [
      quizId,
      ownerId,
      patch.title ?? null,
      patch.subject ?? null,
      patch.description ?? null,
      patch.basePoints ?? null,
      patch.speedBonusMax ?? null,
    ],
  );
  if (!row) throw notFound('Quiz not found.');
  return row;
}

export async function deleteQuiz(quizId, ownerId) {
  const { rowCount } = await query('DELETE FROM quizzes WHERE id = $1 AND owner_id = $2', [
    quizId,
    ownerId,
  ]);
  if (rowCount === 0) throw notFound('Quiz not found.');
}

/** docs/API.md: 409 if fewer than 2 questions or any question is invalid. */
export async function publishQuiz(quizId, ownerId) {
  await ownedQuiz(quizId, ownerId);
  const questions = await listQuestions(quizId);
  if (questions.length < 2) {
    throw conflict('Add at least 2 questions before publishing.', 'questions');
  }
  questions.forEach((q, i) => {
    try {
      validateQuestion(q, { label: `question ${i + 1}` });
    } catch (err) {
      throw conflict(`This quiz cannot be published: ${err.message}`, err.field);
    }
  });
  return setStatus(quizId, ownerId, 'published');
}

export const unpublishQuiz = (quizId, ownerId) => setStatus(quizId, ownerId, 'draft');

async function setStatus(quizId, ownerId, status) {
  const row = await one(
    `WITH upd AS (
       UPDATE quizzes SET status = $3, updated_at = now()
        WHERE id = $1 AND owner_id = $2 RETURNING *
     )
     SELECT ${QUIZ_COLS} FROM upd q`,
    [quizId, ownerId, status],
  );
  if (!row) throw notFound('Quiz not found.');
  return row;
}

// ------------------------------------------------------------- questions -----

export const listQuestions = (quizId) =>
  many(`SELECT ${QUESTION_COLS} FROM questions WHERE quiz_id = $1 ORDER BY order_index`, [quizId]);

/** One question of one quiz, or 404. */
export async function quizQuestion(quizId, questionId) {
  const row = await one(`SELECT ${QUESTION_COLS} FROM questions WHERE id = $1 AND quiz_id = $2`, [
    questionId,
    quizId,
  ]);
  if (!row) throw notFound('Question not found.');
  return row;
}

/**
 * Refuses non-owner question reads while a session of this quiz is open. A live
 * session's questions come from the quiz, so practice mode on the same quiz
 * would otherwise hand out the text — and, graded, the key — mid-game.
 * Sessions abandoned for 12 hours stop counting, so a forgotten lobby cannot
 * lock a quiz forever.
 */
export async function assertNotLive(quizId) {
  const live = await one(
    `SELECT 1 FROM quiz_sessions
      WHERE quiz_id = $1 AND status <> 'ended' AND created_at > now() - interval '12 hours'
      LIMIT 1`,
    [quizId],
  );
  if (live) {
    throw conflict('This quiz is being played live right now. Practise it once the session ends.');
  }
}

/** Appends validated questions after the current last one. */
export async function appendQuestions(quizId, ownerId, rawList) {
  if (!Array.isArray(rawList) || rawList.length === 0) {
    throw validation('questions must be a non-empty array.', 'questions');
  }
  if (rawList.length > 100) throw validation('At most 100 questions per request.', 'questions');
  const clean = rawList.map((raw, i) => validateQuestion(raw, { label: `question ${i + 1}` }));

  return withTransaction(async (client) => {
    const { rows: owner } = await client.query(
      'SELECT id FROM quizzes WHERE id = $1 AND owner_id = $2 FOR UPDATE',
      [quizId, ownerId],
    );
    if (!owner[0]) throw notFound('Quiz not found.');

    const { rows: maxRow } = await client.query(
      'SELECT COALESCE(max(order_index), -1) AS mx FROM questions WHERE quiz_id = $1',
      [quizId],
    );
    let next = Number(maxRow[0].mx) + 1;

    const created = [];
    for (const q of clean) {
      const { rows } = await client.query(
        `INSERT INTO questions
           (quiz_id, question_text, options, correct_index, explanation, difficulty,
            source_reference, order_index, time_limit_seconds)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
         RETURNING ${QUESTION_COLS}`,
        [
          quizId,
          q.question_text,
          JSON.stringify(q.options),
          q.correct_index,
          q.explanation,
          q.difficulty,
          q.source_reference,
          next,
          q.time_limit_seconds,
        ],
      );
      created.push(rows[0]);
      next += 1;
    }
    await client.query('UPDATE quizzes SET updated_at = now() WHERE id = $1', [quizId]);
    return created;
  });
}

/**
 * PUT /questions/:id — replace in place.
 *
 * This is the fix for the confirmed "Regenerate duplicated a question" bug: the
 * row keeps its id and its order_index, so 2 questions stay 2 questions and no
 * two rows can share an order_index.
 */
export async function replaceQuestion(questionId, ownerId, raw) {
  const clean = validateQuestion(raw, { label: 'question' });
  const row = await one(
    `UPDATE questions q SET
        question_text      = $3,
        options            = $4::jsonb,
        correct_index      = $5,
        explanation        = $6,
        difficulty         = $7,
        source_reference   = $8,
        time_limit_seconds = $9
      WHERE q.id = $1
        AND EXISTS (SELECT 1 FROM quizzes z WHERE z.id = q.quiz_id AND z.owner_id = $2)
      RETURNING ${QUESTION_COLS}`,
    [
      questionId,
      ownerId,
      clean.question_text,
      JSON.stringify(clean.options),
      clean.correct_index,
      clean.explanation,
      clean.difficulty,
      clean.source_reference,
      clean.time_limit_seconds,
    ],
  );
  if (!row) throw notFound('Question not found.');
  await query('UPDATE quizzes SET updated_at = now() WHERE id = $1', [row.quiz_id]);
  return row;
}

/** Deletes and closes the gap, so order_index stays 0..n-1 with no holes. */
export async function deleteQuestion(questionId, ownerId) {
  return withTransaction(async (client) => {
    const { rows } = await client.query(
      `DELETE FROM questions q
        WHERE q.id = $1
          AND EXISTS (SELECT 1 FROM quizzes z WHERE z.id = q.quiz_id AND z.owner_id = $2)
        RETURNING q.quiz_id`,
      [questionId, ownerId],
    );
    if (!rows[0]) throw notFound('Question not found.');
    const quizId = rows[0].quiz_id;
    // The UNIQUE constraint is DEFERRABLE INITIALLY DEFERRED, so this one
    // statement can renumber without tripping over itself mid-update.
    await client.query(
      `UPDATE questions t SET order_index = r.rn
         FROM (SELECT id, (row_number() OVER (ORDER BY order_index) - 1)::int AS rn
                 FROM questions WHERE quiz_id = $1) r
        WHERE t.id = r.id AND t.order_index <> r.rn`,
      [quizId],
    );
    await client.query('UPDATE quizzes SET updated_at = now() WHERE id = $1', [quizId]);
    return quizId;
  });
}

export async function reorderQuestions(quizId, ownerId, orderedIds) {
  if (!Array.isArray(orderedIds) || orderedIds.length === 0) {
    throw validation('ordered_ids must be a non-empty array.', 'ordered_ids');
  }
  return withTransaction(async (client) => {
    const { rows: owner } = await client.query(
      'SELECT id FROM quizzes WHERE id = $1 AND owner_id = $2 FOR UPDATE',
      [quizId, ownerId],
    );
    if (!owner[0]) throw notFound('Quiz not found.');

    const { rows: current } = await client.query(
      'SELECT id FROM questions WHERE quiz_id = $1',
      [quizId],
    );
    const have = new Set(current.map((r) => r.id));
    const want = new Set(orderedIds);
    if (want.size !== orderedIds.length) {
      throw validation('ordered_ids contains a duplicate.', 'ordered_ids');
    }
    if (want.size !== have.size || [...want].some((id) => !have.has(id))) {
      throw validation(
        'ordered_ids must list exactly the questions in this quiz, once each.',
        'ordered_ids',
      );
    }
    for (let i = 0; i < orderedIds.length; i += 1) {
      await client.query('UPDATE questions SET order_index = $2 WHERE id = $1', [
        orderedIds[i],
        i,
      ]);
    }
    await client.query('UPDATE quizzes SET updated_at = now() WHERE id = $1', [quizId]);
    const { rows } = await client.query(
      `SELECT ${QUESTION_COLS} FROM questions WHERE quiz_id = $1 ORDER BY order_index`,
      [quizId],
    );
    return rows;
  });
}

/** Ownership check used by the question-level routes before they read. */
export async function ownedQuestion(questionId, ownerId) {
  const row = await one(
    `SELECT ${QUESTION_COLS} FROM questions q
      WHERE q.id = $1
        AND EXISTS (SELECT 1 FROM quizzes z WHERE z.id = q.quiz_id AND z.owner_id = $2)`,
    [questionId, ownerId],
  );
  if (!row) throw notFound('Question not found.');
  return row;
}
