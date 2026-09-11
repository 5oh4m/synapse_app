// Leaderboard as a live SQL aggregate over responses + session_participants.
//
// Defect fixed: the old endpoint read from a denormalised `cumulative` map that
// only ever grew, and it accepted `period` and `subject` and then ignored both —
// so the UI's week/all-time toggle and its subject filter were dead controls.
// There is no cumulative table here; the filters are WHERE clauses, so they
// cannot silently stop working.
import { Router } from 'express';
import { many } from '../db/pool.js';
import { requireAuth } from '../middleware/auth.js';
import { validation } from '../errors.js';

export const leaderboardRoutes = Router();

const PERIODS = {
  week: '7 days',
  month: '30 days',
  'all-time': null,
};

async function board({ period, subject, limit }) {
  const interval = PERIODS[period];
  const params = [];
  const where = [`s.status = 'ended'`];

  if (interval) {
    params.push(interval);
    where.push(`r.answered_at >= now() - $${params.length}::interval`);
  }
  if (subject) {
    params.push(subject);
    where.push(`z.subject IS NOT NULL AND lower(z.subject) = lower($${params.length})`);
  }
  params.push(limit);

  // Points come from `responses`, so the period filter bites at the row level
  // rather than at the session level: a week window counts exactly the answers
  // given inside that week.
  const rows = await many(
    `SELECT p.user_id                                        AS student_id,
            max(p.display_name)                              AS display_name,
            COALESCE(sum(r.points_awarded), 0)::int          AS points,
            count(DISTINCT r.session_id)::int                AS quizzes_played,
            count(*) FILTER (WHERE r.selected_index >= 0)::int AS answered,
            count(*) FILTER (WHERE r.is_correct)::int        AS correct
       FROM responses r
       JOIN session_participants p ON p.id = r.participant_id
       JOIN quiz_sessions s        ON s.id = r.session_id
       JOIN quizzes z              ON z.id = s.quiz_id
       JOIN users u                ON u.id = p.user_id
      WHERE ${where.join(' AND ')}
        AND u.role = 'student'
      GROUP BY p.user_id
      ORDER BY points DESC, display_name ASC
      LIMIT $${params.length}`,
    params,
  );

  return rows.map((r, i) => ({
    student_id: r.student_id,
    display_name: r.display_name,
    points: r.points,
    rank: i + 1,
    quizzes_played: r.quizzes_played,
    correct_rate: r.answered > 0 ? r.correct / r.answered : 0,
  }));
}

function parseParams(query) {
  const period = String(query.period || 'all-time');
  if (!(period in PERIODS)) {
    throw validation(`period must be one of: ${Object.keys(PERIODS).join(', ')}.`, 'period');
  }
  const subject = query.subject ? String(query.subject).trim() : null;
  const limit = Math.min(500, Math.max(1, Number(query.limit) || 100));
  return { period, subject: subject || null, limit };
}

leaderboardRoutes.get('/global', requireAuth, async (req, res) => {
  const { period, subject, limit } = parseParams(req.query);
  res.json(await board({ period, subject, limit }));
});

/** Same aggregate, exposed at the bare path the client may prefer. */
leaderboardRoutes.get('/', requireAuth, async (req, res) => {
  const { period, subject, limit } = parseParams(req.query);
  res.json(await board({ period, subject, limit }));
});

/** Subjects that actually have played results, to populate the filter. */
leaderboardRoutes.get('/subjects', requireAuth, async (_req, res) => {
  const rows = await many(
    `SELECT DISTINCT z.subject
       FROM quizzes z
       JOIN quiz_sessions s ON s.quiz_id = z.id AND s.status = 'ended'
      WHERE z.subject IS NOT NULL AND z.subject <> ''
      ORDER BY z.subject`,
  );
  res.json(rows.map((r) => r.subject));
});
