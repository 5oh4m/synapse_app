import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  resetDb,
  shutdown,
  makeUser,
  makePublishedQuiz,
  makeLiveSession,
  query,
} from './helpers.js';

before(resetDb);
beforeEach(resetDb);
after(shutdown);

/** Plays a whole session to the end so its rows count toward the board. */
async function playSession(educator, quizId, students, { subject } = {}) {
  const { session } = await makeLiveSession(educator, quizId, students);
  await educator.post(`/api/sessions/${session.id}/start`).send({});
  for (const s of students) {
    await s.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });
  }
  await educator.post(`/api/sessions/${session.id}/reveal`).send({});
  await educator.post(`/api/sessions/${session.id}/next`).send({});
  for (const s of students) {
    await s.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });
  }
  await educator.post(`/api/sessions/${session.id}/next`).send({});
  const { rows } = await query('SELECT status FROM quiz_sessions WHERE id = $1', [session.id]);
  assert.equal(rows[0].status, 'ended', `session did not end (subject ${subject})`);
  return session;
}

/** Moves one student's answers into the past. */
const ageResponses = (sessionId, userId, days) =>
  query(
    `UPDATE responses r
        SET answered_at = now() - make_interval(days => $3::int)
       FROM session_participants p
      WHERE p.id = r.participant_id AND r.session_id = $1 AND p.user_id = $2`,
    [sessionId, userId, days],
  );

describe('leaderboard period filter actually filters', () => {
  test('period=week genuinely differs from all-time', async () => {
    const educator = await makeUser({ role: 'educator' });
    const recent = await makeUser({ role: 'student', name: 'Recent Rita' });
    const ancient = await makeUser({ role: 'student', name: 'Ancient Arthur' });
    const { quiz } = await makePublishedQuiz(educator, { count: 2 });

    const session = await playSession(educator, quiz.id, [recent, ancient]);
    // Arthur played 30 days ago; Rita played just now.
    await ageResponses(session.id, ancient.id, 30);

    const allTime = await educator.get('/api/leaderboard/global?period=all-time');
    assert.equal(allTime.status, 200);
    const allNames = allTime.body.map((e) => e.display_name).sort();
    assert.deepEqual(allNames, ['Ancient Arthur', 'Recent Rita']);

    const week = await educator.get('/api/leaderboard/global?period=week');
    assert.equal(week.status, 200);
    const weekNames = week.body.map((e) => e.display_name);
    assert.deepEqual(weekNames, ['Recent Rita'], 'period=week was ignored');

    assert.notDeepEqual(
      week.body,
      allTime.body,
      'week and all-time returned identical payloads, so the filter is dead',
    );
    assert.equal(week.body.length, 1);
    assert.equal(week.body[0].rank, 1);
    assert.ok(week.body[0].points > 0);

    const month = await educator.get('/api/leaderboard/global?period=month');
    assert.deepEqual(
      month.body.map((e) => e.display_name),
      ['Recent Rita'],
      'a 30-day-old result must fall outside period=month',
    );
  });

  test('week counts only the points earned inside the window, not the whole total', async () => {
    const educator = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student', name: 'Split Sam' });
    const { quiz } = await makePublishedQuiz(educator, { count: 2 });

    const old = await playSession(educator, quiz.id, [student]);
    await ageResponses(old.id, student.id, 20);
    const fresh = await playSession(educator, quiz.id, [student]);
    assert.ok(fresh.id);

    const allTime = (await educator.get('/api/leaderboard/global?period=all-time')).body;
    const week = (await educator.get('/api/leaderboard/global?period=week')).body;

    assert.equal(allTime.length, 1);
    assert.equal(week.length, 1);
    assert.equal(allTime[0].quizzes_played, 2);
    assert.equal(week[0].quizzes_played, 1, 'the aged session leaked into the week window');
    assert.ok(
      week[0].points < allTime[0].points,
      `week (${week[0].points}) should be a strict subset of all-time (${allTime[0].points})`,
    );
  });

  test('an unknown period is a field-level 422 rather than silently ignored', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator.get('/api/leaderboard/global?period=fortnight');
    assert.equal(res.status, 422);
    assert.equal(res.body.error.field, 'period');
  });
});

describe('leaderboard subject filter actually filters', () => {
  test('subject=Biology excludes a Chemistry session', async () => {
    const educator = await makeUser({ role: 'educator' });
    const bio = await makeUser({ role: 'student', name: 'Bio Bea' });
    const chem = await makeUser({ role: 'student', name: 'Chem Cai' });

    const { quiz: bioQuiz } = await makePublishedQuiz(educator, { count: 2, subject: 'Biology' });
    const { quiz: chemQuiz } = await makePublishedQuiz(educator, { count: 2, subject: 'Chemistry' });

    await playSession(educator, bioQuiz.id, [bio], { subject: 'Biology' });
    await playSession(educator, chemQuiz.id, [chem], { subject: 'Chemistry' });

    const all = (await educator.get('/api/leaderboard/global')).body;
    assert.equal(all.length, 2);

    const biology = (await educator.get('/api/leaderboard/global?subject=Biology')).body;
    assert.deepEqual(
      biology.map((e) => e.display_name),
      ['Bio Bea'],
      'the subject filter was ignored',
    );

    const chemistry = (await educator.get('/api/leaderboard/global?subject=chemistry')).body;
    assert.deepEqual(
      chemistry.map((e) => e.display_name),
      ['Chem Cai'],
      'the subject filter should be case-insensitive',
    );

    const none = (await educator.get('/api/leaderboard/global?subject=Geography')).body;
    assert.deepEqual(none, []);
  });

  test('period and subject compose', async () => {
    const educator = await makeUser({ role: 'educator' });
    const a = await makeUser({ role: 'student', name: 'Old Bio' });
    const b = await makeUser({ role: 'student', name: 'New Bio' });
    const { quiz } = await makePublishedQuiz(educator, { count: 2, subject: 'Biology' });

    const oldSession = await playSession(educator, quiz.id, [a]);
    await ageResponses(oldSession.id, a.id, 14);
    await playSession(educator, quiz.id, [b]);

    const res = (await educator.get('/api/leaderboard/global?period=week&subject=Biology')).body;
    assert.deepEqual(
      res.map((e) => e.display_name),
      ['New Bio'],
    );
  });

  test('/leaderboard/subjects lists only subjects with played results', async () => {
    const educator = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student' });
    const { quiz } = await makePublishedQuiz(educator, { count: 2, subject: 'Biology' });
    await makePublishedQuiz(educator, { count: 2, subject: 'Never Played' });
    await playSession(educator, quiz.id, [student]);

    const res = await educator.get('/api/leaderboard/subjects');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, ['Biology']);
  });
});

describe('leaderboard shape', () => {
  test('entries are ranked, carry a correct_rate, and exclude educators', async () => {
    const educator = await makeUser({ role: 'educator', name: 'Teacher T' });
    const good = await makeUser({ role: 'student', name: 'All Correct' });
    const { quiz } = await makePublishedQuiz(educator, { count: 2 });
    await playSession(educator, quiz.id, [good]);

    const res = await educator.get('/api/leaderboard/global');
    assert.equal(res.status, 200);
    assert.equal(res.body.length, 1);
    const entry = res.body[0];
    assert.equal(entry.student_id, good.id);
    assert.equal(entry.rank, 1);
    assert.equal(entry.quizzes_played, 1);
    assert.equal(entry.correct_rate, 1);
    assert.ok(entry.points > 0);
    assert.ok(!res.body.some((e) => e.display_name === 'Teacher T'), 'an educator is on the board');
  });

  test('a session still in progress does not appear', async () => {
    const educator = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student' });
    const { quiz } = await makePublishedQuiz(educator, { count: 2 });
    const { session } = await makeLiveSession(educator, quiz.id, [student]);
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await student.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });

    const res = await educator.get('/api/leaderboard/global');
    assert.deepEqual(res.body, [], 'an unfinished session leaked onto the board');
  });

  test('the leaderboard needs authentication', async () => {
    const { api } = await import('./helpers.js');
    assert.equal((await api().get('/api/leaderboard/global')).status, 401);
  });
});
