import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  resetDb,
  shutdown,
  makeUser,
  makePublishedQuiz,
  makeLiveSession,
  sampleQuestions,
  query,
  errorCode,
} from './helpers.js';

before(resetDb);
beforeEach(resetDb);
after(shutdown);

describe('a published quiz never serves its key to students (second audit SEC-6)', () => {
  test('the owner reads the key; anyone else reads redacted questions', async () => {
    const owner = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student' });
    const { quiz } = await makePublishedQuiz(owner, { count: 2 });

    const mine = await owner.get(`/api/quizzes/${quiz.id}/questions`);
    assert.equal(mine.body[0].correct_index, 0);
    assert.ok(mine.body[0].explanation.length > 0);

    const theirs = await student.get(`/api/quizzes/${quiz.id}/questions`);
    assert.equal(theirs.status, 200);
    assert.ok(theirs.body.every((q) => q.correct_index === -1 && q.explanation === ''));
    assert.equal(theirs.body[0].question_text, mine.body[0].question_text);
  });

  test('while a session of the quiz is open, students get neither questions nor grading', async () => {
    const owner = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student' });
    const { quiz, questions } = await makePublishedQuiz(owner, { count: 2 });
    const { session } = await makeLiveSession(owner, quiz.id, [student]);
    await owner.post(`/api/sessions/${session.id}/start`).send({});

    const list = await student.get(`/api/quizzes/${quiz.id}/questions`);
    assert.equal(list.status, 409, 'the live quiz questions were served');
    assert.ok(!JSON.stringify(list.body).includes('correct_index'));

    const grade = await student
      .post(`/api/quizzes/${quiz.id}/practice/answer`)
      .send({ question_id: questions[0].id, selected_index: 1 });
    assert.equal(grade.status, 409, 'practice grading revealed the live key');

    await owner.post(`/api/sessions/${session.id}/end`).send({});
    const later = await student.get(`/api/quizzes/${quiz.id}/questions`);
    assert.equal(later.status, 200);
  });

  test('practice answers are graded on the server', async () => {
    const owner = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student' });
    const { quiz, questions } = await makePublishedQuiz(owner, { count: 2 });

    const wrong = await student
      .post(`/api/quizzes/${quiz.id}/practice/answer`)
      .send({ question_id: questions[0].id, selected_index: 2 });
    assert.equal(wrong.status, 200);
    assert.equal(wrong.body.is_correct, false);
    assert.equal(wrong.body.correct_index, 0);

    const right = await student
      .post(`/api/quizzes/${quiz.id}/practice/answer`)
      .send({ question_id: questions[1].id, selected_index: 0 });
    assert.equal(right.body.is_correct, true);

    const foreign = await student
      .post(`/api/quizzes/${quiz.id}/practice/answer`)
      .send({ question_id: '00000000-0000-4000-8000-000000000000', selected_index: 0 });
    assert.equal(foreign.status, 404);
  });

  test('practice on a draft quiz is 404 for anyone but the owner', async () => {
    const owner = await makeUser({ role: 'educator' });
    const student = await makeUser({ role: 'student' });
    const draft = (await owner.post('/api/quizzes').send({ title: 'Draft' })).body;
    const added = await owner
      .post(`/api/quizzes/${draft.id}/questions`)
      .send({ questions: sampleQuestions(2) });
    const res = await student
      .post(`/api/quizzes/${draft.id}/practice/answer`)
      .send({ question_id: added.body[0].id, selected_index: 0 });
    assert.equal(res.status, 404);
  });
});

describe('quiz authorization (the IDOR the audit found)', () => {
  test('a non-owner educator cannot DELETE someone else\'s quiz — 404, and it survives', async () => {
    const owner = await makeUser({ role: 'educator' });
    const attacker = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(owner);

    const res = await attacker.del(`/api/quizzes/${quiz.id}`);
    assert.equal(res.status, 404, 'must be 404, not 403: existence must not leak');
    assert.equal(errorCode(res), 'NOT_FOUND');

    const { rows } = await query('SELECT id FROM quizzes WHERE id = $1', [quiz.id]);
    assert.equal(rows.length, 1, 'the quiz was deleted by a stranger');
  });

  test('an anonymous DELETE is 401, not a silent success', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(owner);
    const { api } = await import('./helpers.js');
    const res = await api().delete(`/api/quizzes/${quiz.id}`);
    assert.equal(res.status, 401);
    const { rows } = await query('SELECT id FROM quizzes WHERE id = $1', [quiz.id]);
    assert.equal(rows.length, 1);
  });

  test('a non-owner cannot PATCH someone else\'s quiz', async () => {
    const owner = await makeUser({ role: 'educator' });
    const attacker = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(owner);

    const res = await attacker.patch(`/api/quizzes/${quiz.id}`).send({ title: 'Pwned' });
    assert.equal(res.status, 404);

    const { rows } = await query('SELECT title FROM quizzes WHERE id = $1', [quiz.id]);
    assert.equal(rows[0].title, 'Test quiz', 'the title was changed by a stranger');
  });

  test('a non-owner cannot publish or unpublish someone else\'s quiz', async () => {
    const owner = await makeUser({ role: 'educator' });
    const attacker = await makeUser({ role: 'educator' });
    const quizRes = await owner.post('/api/quizzes').send({ title: 'Draft quiz' });
    const quizId = quizRes.body.id;
    await owner.post(`/api/quizzes/${quizId}/questions`).send({ questions: sampleQuestions(2) });

    const pub = await attacker.post(`/api/quizzes/${quizId}/publish`).send({});
    assert.equal(pub.status, 404);

    const unpub = await attacker.post(`/api/quizzes/${quizId}/unpublish`).send({});
    assert.equal(unpub.status, 404);

    const { rows } = await query('SELECT status FROM quizzes WHERE id = $1', [quizId]);
    assert.equal(rows[0].status, 'draft', 'status was changed by a stranger');
  });

  test('a student cannot create a quiz', async () => {
    const student = await makeUser({ role: 'student' });
    const res = await student.post('/api/quizzes').send({ title: 'Student quiz' });
    assert.equal(res.status, 403);
    assert.equal(errorCode(res), 'FORBIDDEN');
  });

  test('a non-owner cannot add questions to someone else\'s quiz', async () => {
    const owner = await makeUser({ role: 'educator' });
    const attacker = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(owner, { count: 2 });

    const res = await attacker
      .post(`/api/quizzes/${quiz.id}/questions`)
      .send({ questions: sampleQuestions(1) });
    assert.equal(res.status, 404);

    const { rows } = await query('SELECT count(*)::int AS n FROM questions WHERE quiz_id = $1', [
      quiz.id,
    ]);
    assert.equal(rows[0].n, 2);
  });

  test('GET /quizzes returns only your own', async () => {
    const a = await makeUser({ role: 'educator' });
    const b = await makeUser({ role: 'educator' });
    await makePublishedQuiz(a);
    await makePublishedQuiz(b);

    const res = await a.get('/api/quizzes');
    assert.equal(res.status, 200);
    assert.equal(res.body.length, 1);
    assert.equal(res.body[0].owner_id, a.id);
  });

  test('a draft quiz is invisible to other users, published is readable', async () => {
    const owner = await makeUser({ role: 'educator' });
    const stranger = await makeUser({ role: 'student' });
    const draft = await owner.post('/api/quizzes').send({ title: 'Secret draft' });

    const hidden = await stranger.get(`/api/quizzes/${draft.body.id}`);
    assert.equal(hidden.status, 404);

    const { quiz } = await makePublishedQuiz(owner);
    const visible = await stranger.get(`/api/quizzes/${quiz.id}`);
    assert.equal(visible.status, 200);
    assert.equal(visible.body.id, quiz.id);
  });

  test('owner_id in the body is refused rather than honoured', async () => {
    const a = await makeUser({ role: 'educator' });
    const b = await makeUser({ role: 'educator' });
    const res = await a.post('/api/quizzes').send({ title: 'Planted', owner_id: b.id });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.field, 'owner_id');
  });
});

describe('publishing rules', () => {
  test('publishing a quiz with fewer than 2 questions is 409', async () => {
    const owner = await makeUser({ role: 'educator' });
    const quiz = (await owner.post('/api/quizzes').send({ title: 'Thin quiz' })).body;
    await owner.post(`/api/quizzes/${quiz.id}/questions`).send({ questions: sampleQuestions(1) });

    const res = await owner.post(`/api/quizzes/${quiz.id}/publish`).send({});
    assert.equal(res.status, 409);
    assert.equal(errorCode(res), 'CONFLICT');
    assert.match(res.body.error.message, /at least 2 questions/i);
  });

  test('question validation rejects bad shapes with a field-level 422', async () => {
    const owner = await makeUser({ role: 'educator' });
    const quiz = (await owner.post('/api/quizzes').send({ title: 'Validation' })).body;

    const threeOptions = await owner.post(`/api/quizzes/${quiz.id}/questions`).send({
      questions: [{ question_text: 'Only three?', options: ['a', 'b', 'c'], correct_index: 0 }],
    });
    assert.equal(threeOptions.status, 422);
    assert.equal(threeOptions.body.error.field, 'options');

    const duplicates = await owner.post(`/api/quizzes/${quiz.id}/questions`).send({
      questions: [
        { question_text: 'Dupes?', options: ['a', 'a', 'b', 'c'], correct_index: 0 },
      ],
    });
    assert.equal(duplicates.status, 422);
    assert.equal(duplicates.body.error.field, 'options');

    const badIndex = await owner.post(`/api/quizzes/${quiz.id}/questions`).send({
      questions: [
        { question_text: 'Out of range?', options: ['a', 'b', 'c', 'd'], correct_index: 9 },
      ],
    });
    assert.equal(badIndex.status, 422);
    assert.equal(badIndex.body.error.field, 'correct_index');

    const badTime = await owner.post(`/api/quizzes/${quiz.id}/questions`).send({
      questions: [
        {
          question_text: 'Too fast?',
          options: ['a', 'b', 'c', 'd'],
          correct_index: 0,
          time_limit_seconds: 2,
        },
      ],
    });
    assert.equal(badTime.status, 422);
    assert.equal(badTime.body.error.field, 'time_limit_seconds');
  });
});
