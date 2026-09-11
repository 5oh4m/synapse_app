import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  resetDb,
  shutdown,
  makeUser,
  makePublishedQuiz,
  sampleQuestions,
  query,
} from './helpers.js';

before(resetDb);
beforeEach(resetDb);
after(shutdown);

const questionRows = (quizId) =>
  query('SELECT id, order_index, question_text FROM questions WHERE quiz_id = $1 ORDER BY order_index', [
    quizId,
  ]).then((r) => r.rows);

describe('PUT /questions/:id replaces in place (the Regenerate duplication bug)', () => {
  test('2 questions stay 2 questions, ids and order_index survive', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz, questions } = await makePublishedQuiz(owner, { count: 2 });

    const before = await questionRows(quiz.id);
    assert.equal(before.length, 2);
    assert.deepEqual(
      before.map((r) => r.order_index),
      [0, 1],
    );

    const target = questions[0];
    const res = await owner.put(`/api/questions/${target.id}`).send({
      question_text: 'Regenerated: what replaced the original?',
      options: ['This one', 'Not this', 'Nor this', 'Nor that'],
      correct_index: 0,
      explanation: 'Because the row was updated, not inserted.',
      difficulty: 'hard',
      source_reference: 'Slide 9',
      time_limit_seconds: 30,
    });

    assert.equal(res.status, 200);
    assert.equal(res.body.id, target.id, 'the id changed, so this was an insert not a replace');
    assert.equal(res.body.order_index, target.order_index, 'order_index moved');
    assert.equal(res.body.question_text, 'Regenerated: what replaced the original?');
    assert.equal(res.body.difficulty, 'hard');

    const after = await questionRows(quiz.id);
    assert.equal(after.length, 2, `regenerate duplicated a question: now ${after.length}`);
    assert.deepEqual(
      after.map((r) => r.order_index),
      [0, 1],
      'order_index sequence broke',
    );
    assert.equal(new Set(after.map((r) => r.order_index)).size, 2, 'two rows share an order_index');
  });

  test('replacing ten times in a row still leaves exactly 2 questions', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz, questions } = await makePublishedQuiz(owner, { count: 2 });

    for (let i = 0; i < 10; i += 1) {
      const res = await owner.put(`/api/questions/${questions[0].id}`).send({
        question_text: `Regeneration attempt ${i}: which option is right?`,
        options: [`Right ${i}`, `A ${i}`, `B ${i}`, `C ${i}`],
        correct_index: 0,
        time_limit_seconds: 20,
      });
      assert.equal(res.status, 200);
    }

    const after = await questionRows(quiz.id);
    assert.equal(after.length, 2);
    assert.match(after[0].question_text, /attempt 9/);
  });

  test('the UNIQUE (quiz_id, order_index) constraint exists and is enforced', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(owner, { count: 2 });

    // Bypassing the API entirely: even raw SQL cannot create the duplicate.
    await assert.rejects(
      () =>
        query(
          `INSERT INTO questions
             (quiz_id, question_text, options, correct_index, order_index, time_limit_seconds)
           VALUES ($1, 'Duplicate order index', '["a","b","c","d"]'::jsonb, 0, 0, 20)`,
          [quiz.id],
        ),
      (err) => err.code === '23505',
      'the data layer allowed two questions with the same order_index',
    );
  });

  test('a non-owner cannot replace a question', async () => {
    const owner = await makeUser({ role: 'educator' });
    const attacker = await makeUser({ role: 'educator' });
    const { questions } = await makePublishedQuiz(owner, { count: 2 });

    const res = await attacker.put(`/api/questions/${questions[0].id}`).send({
      question_text: 'Hijacked question text here',
      options: ['x', 'y', 'z', 'w'],
      correct_index: 0,
      time_limit_seconds: 20,
    });
    assert.equal(res.status, 404);

    const rows = await questionRows(questions[0].quiz_id);
    assert.match(rows[0].question_text, /Question number 1/);
  });

  test('a replacement is validated: 3 options is 422 and the row is untouched', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { questions } = await makePublishedQuiz(owner, { count: 2 });
    const res = await owner
      .put(`/api/questions/${questions[0].id}`)
      .send({ question_text: 'Three only', options: ['a', 'b', 'c'], correct_index: 0 });
    assert.equal(res.status, 422);
    assert.equal(res.body.error.field, 'options');

    const rows = await questionRows(questions[0].quiz_id);
    assert.match(rows[0].question_text, /Question number 1/);
  });
});

describe('question append / delete / reorder', () => {
  test('append puts new questions after the existing ones', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz } = await makePublishedQuiz(owner, { count: 2 });

    const res = await owner
      .post(`/api/quizzes/${quiz.id}/questions`)
      .send({ questions: sampleQuestions(3) });
    assert.equal(res.status, 201);
    assert.deepEqual(
      res.body.map((q) => q.order_index),
      [2, 3, 4],
    );

    const rows = await questionRows(quiz.id);
    assert.deepEqual(
      rows.map((r) => r.order_index),
      [0, 1, 2, 3, 4],
    );
  });

  test('delete resequences siblings so there is no hole', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz, questions } = await makePublishedQuiz(owner, { count: 4 });

    const res = await owner.del(`/api/questions/${questions[1].id}`);
    assert.equal(res.status, 204);

    const rows = await questionRows(quiz.id);
    assert.deepEqual(
      rows.map((r) => r.order_index),
      [0, 1, 2],
    );
    assert.ok(!rows.some((r) => r.id === questions[1].id));
  });

  test('reorder rewrites order_index and rejects a partial list', async () => {
    const owner = await makeUser({ role: 'educator' });
    const { quiz, questions } = await makePublishedQuiz(owner, { count: 3 });
    const reversed = [...questions].reverse().map((q) => q.id);

    const res = await owner
      .post(`/api/quizzes/${quiz.id}/questions/reorder`)
      .send({ ordered_ids: reversed });
    assert.equal(res.status, 200);
    assert.deepEqual(
      res.body.map((q) => q.id),
      reversed,
    );

    const partial = await owner
      .post(`/api/quizzes/${quiz.id}/questions/reorder`)
      .send({ ordered_ids: [questions[0].id] });
    assert.equal(partial.status, 422);
    assert.equal(partial.body.error.field, 'ordered_ids');
  });
});
