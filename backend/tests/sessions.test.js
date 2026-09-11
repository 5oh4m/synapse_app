import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  api,
  resetDb,
  shutdown,
  makeUser,
  makePublishedQuiz,
  makeLiveSession,
  query,
  errorCode,
} from './helpers.js';
import { tickAutoReveal } from '../src/services/session.service.js';

before(resetDb);
beforeEach(resetDb);
after(shutdown);

/**
 * Rewinds the clock on the current question so elapsed time is a known,
 * non-zero value without the test having to sleep. question_ends_at stays in
 * the future, so the answer is still in time.
 */
async function backdateQuestion(sessionId, elapsedSeconds, limitSeconds = 20) {
  await query(
    `UPDATE quiz_sessions
        SET question_started_at = now() - make_interval(secs => $2::float),
            question_ends_at    = now() + make_interval(secs => $3::float)
      WHERE id = $1`,
    [sessionId, elapsedSeconds, limitSeconds - elapsedSeconds],
  );
}

async function stage({ studentCount = 1, questionCount = 2 } = {}) {
  const educator = await makeUser({ role: 'educator', name: 'Host Teacher' });
  const students = [];
  for (let i = 0; i < studentCount; i += 1) {
    students.push(await makeUser({ role: 'student', name: `Student ${i + 1}` }));
  }
  const { quiz } = await makePublishedQuiz(educator, { count: questionCount });
  const { session } = await makeLiveSession(educator, quiz.id, students);
  return { educator, students, student: students[0], quiz, session };
}

describe('the answer key never leaves the server early', () => {
  test('a student CANNOT read GET /sessions/:id/questions (host-only answer key)', async () => {
    const { student, session } = await stage();
    const res = await student.get(`/api/sessions/${session.id}/questions`);
    assert.equal(res.status, 404, 'a participant read the host-only answer key');
    assert.equal(errorCode(res), 'NOT_FOUND');
    assert.ok(!JSON.stringify(res.body).includes('correct_index'));
  });

  test('a stranger who is not even in the session gets 404 too', async () => {
    const { session } = await stage();
    const outsider = await makeUser({ role: 'student' });
    const res = await outsider.get(`/api/sessions/${session.id}/questions`);
    assert.equal(res.status, 404);
  });

  test('the host CAN read the full key', async () => {
    const { educator, session } = await stage();
    const res = await educator.get(`/api/sessions/${session.id}/questions`);
    assert.equal(res.status, 200);
    assert.equal(res.body.length, 2);
    assert.equal(res.body[0].correct_index, 0);
    assert.ok(res.body[0].explanation.length > 0);
  });

  test('current-question is redacted for a student until reveal', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});

    const asking = await student.get(`/api/sessions/${session.id}/current-question`);
    assert.equal(asking.status, 200);
    assert.equal(asking.body.question.correct_index, -1, 'the key leaked before reveal');
    assert.equal(asking.body.question.explanation, '');
    assert.equal(asking.body.revealed, false);

    await educator.post(`/api/sessions/${session.id}/reveal`).send({});

    const revealed = await student.get(`/api/sessions/${session.id}/current-question`);
    assert.equal(revealed.body.question.correct_index, 0);
    assert.ok(revealed.body.question.explanation.length > 0);
    assert.equal(revealed.body.revealed, true);
    assert.ok(Array.isArray(revealed.body.distribution));
  });
});

describe('host-only session controls', () => {
  for (const action of ['start', 'reveal', 'next', 'end']) {
    test(`a participant cannot POST /sessions/:id/${action}`, async () => {
      const { educator, student, session } = await stage();
      if (action !== 'start') {
        await educator.post(`/api/sessions/${session.id}/start`).send({});
      }

      const res = await student.post(`/api/sessions/${session.id}/${action}`).send({});
      assert.equal(res.status, 404, `a student was allowed to ${action} the session`);

      const { rows } = await query('SELECT status, phase FROM quiz_sessions WHERE id = $1', [
        session.id,
      ]);
      assert.notEqual(rows[0].status, 'ended', `the student ended the session via ${action}`);
      if (action === 'reveal') assert.equal(rows[0].phase, 'asking');
    });

    test(`another educator cannot POST /sessions/:id/${action}`, async () => {
      const { session } = await stage();
      const rival = await makeUser({ role: 'educator' });
      const res = await rival.post(`/api/sessions/${session.id}/${action}`).send({});
      assert.equal(res.status, 404);
    });

    test(`an anonymous caller cannot POST /sessions/:id/${action}`, async () => {
      const { session } = await stage();
      const res = await api().post(`/api/sessions/${session.id}/${action}`).send({});
      assert.equal(res.status, 401);
    });
  }

  test('the host can run the whole phase machine', async () => {
    const { educator, session } = await stage({ questionCount: 2 });

    const started = await educator.post(`/api/sessions/${session.id}/start`).send({});
    assert.equal(started.status, 200);
    assert.equal(started.body.status, 'active');
    assert.equal(started.body.current_question_index, 0);
    assert.equal(started.body.phase, 'asking');
    assert.ok(started.body.question_ends_at > started.body.question_started_at);

    const revealed = await educator.post(`/api/sessions/${session.id}/reveal`).send({});
    assert.equal(revealed.body.phase, 'revealing');

    const next = await educator.post(`/api/sessions/${session.id}/next`).send({});
    assert.equal(next.body.current_question_index, 1);
    assert.equal(next.body.phase, 'asking');

    const past = await educator.post(`/api/sessions/${session.id}/next`).send({});
    assert.equal(past.body.status, 'ended', 'next past the last question must end the session');
    assert.ok(past.body.ended_at);
  });
});

describe('server-authoritative timing (the cheat the audit found)', () => {
  test('a forged response_time_ms of 1 does NOT inflate the score', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    // 10s of a 20s limit has really elapsed.
    await backdateQuestion(session.id, 10, 20);

    const res = await student
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 0, response_time_ms: 1 });

    assert.equal(res.status, 201);
    assert.equal(res.body.is_correct, true);

    // base 500 + round(500 * (1 - 10/20)) = 750. A trusted "1 ms" would be 1000.
    assert.ok(
      res.body.points_awarded >= 730 && res.body.points_awarded <= 770,
      `expected ~750 from server timing, got ${res.body.points_awarded}`,
    );
    assert.notEqual(res.body.points_awarded, 1000, 'the client clock was trusted');
    assert.ok(
      res.body.response_time_ms >= 9_000,
      `response_time_ms should be the server's ~10000, got ${res.body.response_time_ms}`,
    );
    assert.ok(res.body.ignored_fields.includes('response_time_ms'));

    const { rows } = await query(
      'SELECT response_time_ms, points_awarded FROM responses WHERE session_id = $1',
      [session.id],
    );
    assert.ok(rows[0].response_time_ms >= 9_000, 'the forged 1 ms was persisted');
  });

  test('an honest fast answer still earns the full bonus, so timing is real not capped', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});

    const res = await student
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 0 });
    assert.equal(res.status, 201);
    assert.ok(res.body.points_awarded > 950, `a genuinely instant answer should be ~1000, got ${res.body.points_awarded}`);
  });

  test('a forged tiny time cannot rescue a late answer', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    // The deadline (plus grace) is in the past.
    await query(
      `UPDATE quiz_sessions
          SET question_started_at = now() - interval '30 seconds',
              question_ends_at    = now() - interval '10 seconds'
        WHERE id = $1`,
      [session.id],
    );

    const res = await student
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 0, response_time_ms: 1 });
    assert.equal(res.status, 409);
    assert.match(res.body.error.message, /time is up/i);
  });

  test('a wrong answer scores 0 no matter how fast', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    const res = await student
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 2, response_time_ms: 1 });
    assert.equal(res.body.is_correct, false);
    assert.equal(res.body.points_awarded, 0);
  });
});

describe('identity comes from the JWT, never the body', () => {
  test('answering with somebody else\'s student_id never scores for them', async () => {
    const { educator, students, session } = await stage({ studentCount: 2 });
    const [attacker, victim] = students;
    await educator.post(`/api/sessions/${session.id}/start`).send({});

    const res = await attacker
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 0, student_id: victim.id });

    // docs/API.md rule 1: a body identity field is rejected outright.
    assert.equal(res.status, 400);
    assert.equal(res.body.error.field, 'student_id');

    // Whatever the status code, the security property is that nothing was
    // written against the victim.
    const { rows } = await query(
      `SELECT p.user_id FROM responses r
         JOIN session_participants p ON p.id = r.participant_id
        WHERE r.session_id = $1`,
      [session.id],
    );
    assert.equal(rows.length, 0, 'an answer was recorded despite the rejection');

    const victimRow = await query(
      'SELECT total_score, answered_count FROM session_participants WHERE session_id = $1 AND user_id = $2',
      [session.id, victim.id],
    );
    assert.equal(victimRow.rows[0].total_score, 0, 'the victim was scored by somebody else');
    assert.equal(victimRow.rows[0].answered_count, 0);
  });

  test('a clean answer is attributed to the token subject', async () => {
    const { educator, students, session } = await stage({ studentCount: 2 });
    const [answerer, other] = students;
    await educator.post(`/api/sessions/${session.id}/start`).send({});

    await answerer.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });

    const { rows } = await query(
      `SELECT p.user_id FROM responses r
         JOIN session_participants p ON p.id = r.participant_id
        WHERE r.session_id = $1`,
      [session.id],
    );
    assert.equal(rows.length, 1);
    assert.equal(rows[0].user_id, answerer.id);
    assert.notEqual(rows[0].user_id, other.id);
  });

  test('join uses the token user, not a body payload', async () => {
    const educator = await makeUser({ role: 'educator' });
    const joiner = await makeUser({ role: 'student', name: 'Real Joiner' });
    const victim = await makeUser({ role: 'student', name: 'Victim' });
    const { quiz } = await makePublishedQuiz(educator);
    const { session } = await makeLiveSession(educator, quiz.id);

    const res = await joiner
      .post('/api/sessions/join')
      .send({ join_code: session.join_code, student_id: victim.id });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.field, 'student_id');

    const clean = await joiner.post('/api/sessions/join').send({ join_code: session.join_code });
    assert.equal(clean.status, 201);
    assert.equal(clean.body.user_id, joiner.id);
    assert.equal(clean.body.display_name, 'Real Joiner');
  });

  test('a session is hosted by the token user; host_id in the body is refused', async () => {
    const educator = await makeUser({ role: 'educator' });
    const rival = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(educator);

    const planted = await educator
      .post('/api/sessions')
      .send({ quiz_id: quiz.id, host_id: rival.id });
    assert.equal(planted.status, 400);
    assert.equal(planted.body.error.field, 'host_id');

    const clean = await educator.post('/api/sessions').send({ quiz_id: quiz.id });
    assert.equal(clean.status, 201);
    assert.equal(clean.body.host_id, educator.id);
  });
});

describe('double submit cannot rescore', () => {
  test('the second submit returns the first result with 200 and writes nothing', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await backdateQuestion(session.id, 4, 20);

    const first = await student
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 0 });
    assert.equal(first.status, 201);
    assert.equal(first.body.scored, true);

    // Second submit, now with the correct answer changed and more time elapsed.
    await backdateQuestion(session.id, 18, 20);
    const second = await student
      .post(`/api/sessions/${session.id}/answer`)
      .send({ question_index: 0, selected_index: 1 });

    assert.equal(second.status, 200, 'a resubmit must be 200, not a new 201');
    assert.equal(second.body.scored, false);
    assert.equal(second.body.id, first.body.id, 'a second row was created');
    assert.equal(second.body.points_awarded, first.body.points_awarded, 'the answer was rescored');
    assert.equal(second.body.selected_index, first.body.selected_index);

    const { rows } = await query(
      'SELECT count(*)::int AS n FROM responses WHERE session_id = $1 AND question_index = 0',
      [session.id],
    );
    assert.equal(rows[0].n, 1, 'two rows exist for one (participant, question)');

    const p = await query(
      'SELECT total_score, answered_count FROM session_participants WHERE session_id = $1',
      [session.id],
    );
    assert.equal(p.rows[0].answered_count, 1, 'answered_count was double counted');
    assert.equal(p.rows[0].total_score, first.body.points_awarded, 'the score was added twice');
  });

  test('two concurrent submits produce exactly one scored row', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});

    const results = await Promise.all([
      student.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 }),
      student.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 }),
      student.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 }),
    ]);
    assert.ok(results.every((r) => r.status === 200 || r.status === 201));
    assert.equal(results.filter((r) => r.body.scored).length, 1, 'more than one submit scored');

    const { rows } = await query(
      'SELECT count(*)::int AS n FROM responses WHERE session_id = $1',
      [session.id],
    );
    assert.equal(rows[0].n, 1);
  });

  test('the UNIQUE (participant_id, question_index) constraint is enforced in the data layer', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await student.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });

    const { rows } = await query(
      `SELECT r.participant_id, r.session_question_id FROM responses r WHERE r.session_id = $1`,
      [session.id],
    );
    await assert.rejects(
      () =>
        query(
          `INSERT INTO responses
             (session_id, participant_id, session_question_id, question_index,
              selected_index, is_correct, response_time_ms, points_awarded)
           VALUES ($1, $2, $3, 0, 0, true, 1, 1000)`,
          [session.id, rows[0].participant_id, rows[0].session_question_id],
        ),
      (err) => err.code === '23505',
    );
  });
});

describe('join and session reads', () => {
  test('join is idempotent and keeps the score', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await student.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });

    const rejoin = await student.post('/api/sessions/join').send({ join_code: session.join_code });
    assert.equal(rejoin.status, 201);
    assert.ok(rejoin.body.total_score > 0, 'rejoining reset the score');

    const { rows } = await query(
      'SELECT count(*)::int AS n FROM session_participants WHERE session_id = $1',
      [session.id],
    );
    assert.equal(rows[0].n, 1, 'rejoining created a second participant row');
  });

  test('an educator cannot join as a player', async () => {
    const { educator, session } = await stage();
    const other = await makeUser({ role: 'educator' });
    const res = await other.post('/api/sessions/join').send({ join_code: session.join_code });
    assert.equal(res.status, 403);
    assert.ok(educator);
  });

  test('by-code returns only the four public fields', async () => {
    const { student, session } = await stage();
    const res = await student.get(`/api/sessions/by-code/${session.join_code}`);
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), [
      'id',
      'question_count',
      'quiz_title',
      'status',
    ]);
  });

  test('a wrong join code is 404', async () => {
    const { student } = await stage();
    const res = await student.post('/api/sessions/join').send({ join_code: 'ZZZZZZ' });
    assert.equal(res.status, 404);
  });

  test('GET /sessions/:id is 404 for a non-member', async () => {
    const { session } = await stage();
    const outsider = await makeUser({ role: 'student' });
    assert.equal((await outsider.get(`/api/sessions/${session.id}`)).status, 404);
    assert.equal((await outsider.get(`/api/sessions/${session.id}/participants`)).status, 404);
    assert.equal((await outsider.get(`/api/sessions/${session.id}/results`)).status, 404);
  });
});

describe('the session snapshot freezes what is being played', () => {
  test('editing the quiz mid-session does not change the live questions', async () => {
    const { educator, quiz, session } = await stage({ questionCount: 2 });
    const questions = (await educator.get(`/api/quizzes/${quiz.id}/questions`)).body;

    await educator.post(`/api/sessions/${session.id}/start`).send({});

    const replaced = await educator.put(`/api/questions/${questions[0].id}`).send({
      question_text: 'EDITED MID GAME: what is being played?',
      options: ['Changed A', 'Changed B', 'Changed C', 'Changed D'],
      correct_index: 3,
      time_limit_seconds: 20,
    });
    assert.equal(replaced.status, 200);

    const live = (await educator.get(`/api/sessions/${session.id}/questions`)).body;
    assert.match(live[0].question_text, /Question number 1/, 'the live question changed mid-game');
    assert.equal(live[0].correct_index, 0, 'the live answer key changed mid-game');
  });

  test('deleting the quiz question mid-session leaves the session playable', async () => {
    const { educator, quiz, session } = await stage({ questionCount: 3 });
    const questions = (await educator.get(`/api/quizzes/${quiz.id}/questions`)).body;
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await educator.del(`/api/questions/${questions[2].id}`);

    const live = (await educator.get(`/api/sessions/${session.id}/questions`)).body;
    assert.equal(live.length, 3, 'the snapshot lost a question');
  });
});

describe('server-side auto reveal', () => {
  test('the timer reveals a question whose deadline has passed, with no host action', async () => {
    const { educator, student, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});

    // The host's laptop has gone to sleep; nobody is going to press reveal.
    await query(
      `UPDATE quiz_sessions
          SET question_started_at = now() - interval '25 seconds',
              question_ends_at    = now() - interval '5 seconds'
        WHERE id = $1`,
      [session.id],
    );

    const revealedCount = await tickAutoReveal();
    assert.ok(revealedCount >= 1, 'the auto-reveal timer did not pick up the due question');

    const { rows } = await query('SELECT phase FROM quiz_sessions WHERE id = $1', [session.id]);
    assert.equal(rows[0].phase, 'revealing');

    // The student now sees the key, and got a 0 for not answering.
    const view = await student.get(`/api/sessions/${session.id}/current-question`);
    assert.equal(view.body.revealed, true);
    assert.equal(view.body.question.correct_index, 0);

    const resp = await query('SELECT selected_index, points_awarded FROM responses WHERE session_id = $1', [
      session.id,
    ]);
    assert.equal(resp.rows.length, 1, 'a non-answer was not zero-filled');
    assert.equal(resp.rows[0].selected_index, -1);
    assert.equal(resp.rows[0].points_awarded, 0);
  });

  test('the timer leaves a live question alone', async () => {
    const { educator, session } = await stage();
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await tickAutoReveal();
    const { rows } = await query('SELECT phase FROM quiz_sessions WHERE id = $1', [session.id]);
    assert.equal(rows[0].phase, 'asking');
  });
});

describe('results', () => {
  test('the full happy path produces a ranked board and a per-question breakdown', async () => {
    const { educator, students, session } = await stage({ studentCount: 2, questionCount: 2 });
    const [fast, slow] = students;

    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await backdateQuestion(session.id, 2, 20);
    await fast.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });
    await backdateQuestion(session.id, 16, 20);
    await slow.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });

    await educator.post(`/api/sessions/${session.id}/reveal`).send({});
    await educator.post(`/api/sessions/${session.id}/next`).send({});
    await fast.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });
    await slow.post(`/api/sessions/${session.id}/answer`).send({ selected_index: 3 });
    const ended = await educator.post(`/api/sessions/${session.id}/next`).send({});
    assert.equal(ended.body.status, 'ended');

    const board = await educator.get(`/api/sessions/${session.id}/results`);
    assert.equal(board.status, 200);
    assert.equal(board.body.scoreboard.length, 2);
    assert.equal(board.body.scoreboard[0].rank, 1);
    assert.equal(
      board.body.scoreboard[0].display_name,
      'Student 1',
      'the faster, more correct student should be first',
    );
    assert.ok(
      board.body.scoreboard[0].total_score > board.body.scoreboard[1].total_score,
      'answering faster and more correctly did not win',
    );

    const mine = await slow.get(`/api/sessions/${session.id}/results`);
    assert.equal(mine.status, 200);
    assert.equal(mine.body.my_breakdown.length, 2);
    assert.equal(mine.body.my_breakdown[0].is_correct, true);
    assert.equal(mine.body.my_breakdown[1].is_correct, false);
  });

  test('everyone who never answered is zero-filled when the session ends', async () => {
    const { educator, students, session } = await stage({ studentCount: 2, questionCount: 2 });
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await students[0].post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });
    await educator.post(`/api/sessions/${session.id}/end`).send({});

    const { rows } = await query(
      'SELECT count(*)::int AS n FROM responses WHERE session_id = $1',
      [session.id],
    );
    assert.equal(rows[0].n, 2, 'the silent student was not zero-filled');
  });
});
