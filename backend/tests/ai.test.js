import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import { resetDb, shutdown, makeUser } from './helpers.js';
import { config } from '../src/config.js';
import {
  extractJsonObjects,
  parseJsonFromText,
  resolveDifficulties,
  generate,
} from '../src/services/ai.service.js';

before(resetDb);
beforeEach(resetDb);
after(shutdown);

const hasQuestions = (v) => v && Array.isArray(v.questions);

describe('the model id is real', () => {
  test('the default model is claude-sonnet-4-20250514, not the hallucinated sonnet-5', () => {
    assert.equal(config.ai.model, 'claude-sonnet-4-20250514');
    assert.notEqual(config.ai.model, 'claude-sonnet-5');
  });
});

describe('brace-matching JSON scanner', () => {
  test('prose containing braces does not break the bounds', () => {
    // indexOf('{') + lastIndexOf('}') slices from the first brace in the prose
    // to the last one, producing garbage. This is the exact old failure.
    const reply =
      'Sure! Use {placeholder} syntax where needed. Here is the JSON:\n' +
      '{"questions":[{"question_text":"Q","options":["a","b","c","d"],"correct_index":0}]}\n' +
      'Let me know if you want a different {format}.';

    const naive = reply.slice(reply.indexOf('{'), reply.lastIndexOf('}') + 1);
    assert.throws(() => JSON.parse(naive), 'the naive slice should be unparsable');

    const parsed = parseJsonFromText(reply, hasQuestions);
    assert.ok(parsed, 'the scanner failed where it should succeed');
    assert.equal(parsed.questions.length, 1);
    assert.equal(parsed.questions[0].question_text, 'Q');
  });

  test('braces inside string literals are ignored', () => {
    const reply =
      '{"questions":[{"question_text":"What does {x} mean in the notation }{ ?",' +
      '"options":["a","b","c","d"],"correct_index":1}]}';
    const parsed = parseJsonFromText(reply, hasQuestions);
    assert.ok(parsed);
    assert.equal(parsed.questions[0].correct_index, 1);
    assert.match(parsed.questions[0].question_text, /\{x\}/);
  });

  test('escaped quotes inside strings do not end the string early', () => {
    const reply =
      'Here you go:\n```json\n' +
      '{"questions":[{"question_text":"He said \\"use {this}\\" out loud",' +
      '"options":["w","x","y","z"],"correct_index":2}]}\n```';
    const parsed = parseJsonFromText(reply, hasQuestions);
    assert.ok(parsed);
    assert.equal(parsed.questions[0].correct_index, 2);
    assert.match(parsed.questions[0].question_text, /He said "use \{this\}" out loud/);
  });

  test('a stray closing brace before the real object is skipped', () => {
    const reply = 'Oops } I mean:\n{"questions":[{"question_text":"Q2","options":["a","b","c","d"],"correct_index":0}]}';
    const parsed = parseJsonFromText(reply, hasQuestions);
    assert.ok(parsed);
    assert.equal(parsed.questions[0].question_text, 'Q2');
  });

  test('two JSON blocks: the one that satisfies the predicate is chosen', () => {
    const reply =
      '{"note":"this block has no questions array at all, and is quite long indeed"}\n' +
      'and then\n' +
      '{"questions":[{"question_text":"Q3","options":["a","b","c","d"],"correct_index":0}]}';
    const parsed = parseJsonFromText(reply, hasQuestions);
    assert.ok(parsed);
    assert.ok(Array.isArray(parsed.questions));
    assert.equal(parsed.questions[0].question_text, 'Q3');
  });

  test('nested objects are returned as one balanced candidate', () => {
    const found = extractJsonObjects('prefix {"a":{"b":{"c":1}}} suffix {"d":2}');
    assert.equal(found.length, 2);
    assert.equal(found[0], '{"a":{"b":{"c":1}}}');
    assert.equal(found[1], '{"d":2}');
  });

  test('unbalanced input yields nothing instead of throwing', () => {
    assert.deepEqual(extractJsonObjects('{"unterminated": "value'), []);
    assert.deepEqual(extractJsonObjects('no json here at all'), []);
    assert.deepEqual(extractJsonObjects(''), []);
    assert.deepEqual(extractJsonObjects(null), []);
    assert.equal(parseJsonFromText('nothing parsable', hasQuestions), null);
  });

  test('a very long unbalanced prefix does not hang or throw', () => {
    const junk = `${'{'.repeat(5000)} unterminated`;
    assert.doesNotThrow(() => extractJsonObjects(junk));
    assert.deepEqual(extractJsonObjects(junk), []);
  });
});

describe('difficulty mix', () => {
  test('weights are spread across the requested count', () => {
    const mix = resolveDifficulties({ easy: 1, medium: 1, hard: 2 }, 8);
    assert.equal(mix.length, 8);
    assert.equal(mix.filter((d) => d === 'hard').length, 4);
    assert.equal(mix.filter((d) => d === 'easy').length, 2);
  });

  test('an empty or nonsense mix falls back to medium', () => {
    assert.deepEqual(resolveDifficulties({}, 3), ['medium', 'medium', 'medium']);
    assert.deepEqual(resolveDifficulties({ impossible: 5 }, 2), ['medium', 'medium']);
    assert.deepEqual(resolveDifficulties(null, 1), ['medium']);
  });
});

const SOURCE = `
Photosynthesis converts light energy into chemical energy stored in glucose. The light dependent
reactions take place in the thylakoid membranes of the chloroplast. Water is split by photolysis,
which releases oxygen as a by product. The Calvin cycle occurs in the stroma and fixes carbon
dioxide using the enzyme RuBisCO. Light intensity, carbon dioxide concentration and temperature
all limit the overall rate of the reaction.
`.trim();

describe('the mock generator returns spec-valid questions', () => {
  test('every question satisfies the write-time validation rules', async () => {
    const out = await generate({ sourceText: SOURCE, count: 5, difficultyMix: { medium: 1 } });
    assert.equal(out.provider, 'mock');
    assert.equal(out.questions.length, 5);
    for (const q of out.questions) {
      assert.ok(q.question_text.length > 0);
      assert.equal(q.options.length, 4);
      assert.equal(new Set(q.options).size, 4, 'options must be distinct');
      assert.ok(q.options.every((o) => o.length > 0));
      assert.ok(q.correct_index >= 0 && q.correct_index <= 3);
      assert.ok(['easy', 'medium', 'hard'].includes(q.difficulty));
      assert.ok(q.time_limit_seconds >= 5 && q.time_limit_seconds <= 120);
    }
  });
});

describe('POST /generate', () => {
  test('an educator gets questions that can be saved straight onto a quiz', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator
      .post('/api/generate')
      .send({ source_text: SOURCE, count: 3, difficulty_mix: { easy: 1, medium: 1 } });

    assert.equal(res.status, 200);
    assert.equal(res.body.questions.length, 3);
    assert.equal(res.body.provider, 'mock');

    const quiz = (await educator.post('/api/quizzes').send({ title: 'Generated' })).body;
    const saved = await educator
      .post(`/api/quizzes/${quiz.id}/questions`)
      .send({ questions: res.body.questions });
    assert.equal(saved.status, 201, `generated output was rejected: ${JSON.stringify(saved.body)}`);
  });

  test('a student cannot generate', async () => {
    const student = await makeUser({ role: 'student' });
    const res = await student.post('/api/generate').send({ source_text: SOURCE, count: 2 });
    assert.equal(res.status, 403);
  });

  test('too little source text is a field-level 422', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator.post('/api/generate').send({ source_text: 'tiny', count: 2 });
    assert.equal(res.status, 422);
    assert.equal(res.body.error.field, 'source_text');
  });

  test('generating from another educator\'s content is 404', async () => {
    const owner = await makeUser({ role: 'educator' });
    const other = await makeUser({ role: 'educator' });
    const item = await owner
      .post('/api/content')
      .send({ title: 'Notes', source_type: 'text', raw_text: SOURCE });
    assert.equal(item.body.status, 'ready');

    const res = await other.post('/api/generate').send({ content_id: item.body.id, count: 2 });
    assert.equal(res.status, 404);

    const mine = await owner.post('/api/generate').send({ content_id: item.body.id, count: 2 });
    assert.equal(mine.status, 200);
    assert.equal(mine.body.questions.length, 2);
  });
});
