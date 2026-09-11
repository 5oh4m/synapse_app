// Shared test scaffolding. Every file gets its own process under `node --test`,
// so module-level state (the rate limiters, the pool) is never shared between
// files.
process.env.NODE_ENV = 'test';

import request from 'supertest';
import { createApp } from '../src/app.js';
import { pool, query } from '../src/db/pool.js';

export { pool, query, request };

export const app = createApp();
export const api = () => request(app);

const TABLES = [
  'responses',
  'session_participants',
  'session_questions',
  'quiz_sessions',
  'questions',
  'quizzes',
  'content_items',
  'refresh_tokens',
  'users',
];

export async function resetDb() {
  await query(`TRUNCATE ${TABLES.join(', ')} RESTART IDENTITY CASCADE`);
}

export async function shutdown() {
  await pool.end();
}

let counter = 0;
export const uniqueEmail = (prefix = 'user') =>
  `${prefix}.${process.pid}.${counter++}.${Date.now().toString(36)}@test.quizzle`;

/** Registers an account and returns tokens plus a pre-authenticated helper. */
export async function makeUser({ role = 'student', name, email, password = 'test-password-1' } = {}) {
  const body = {
    name: name || (role === 'educator' ? 'Test Educator' : 'Test Student'),
    email: email || uniqueEmail(role),
    password,
    role,
  };
  const res = await api().post('/api/auth/register').send(body);
  if (res.status !== 201) {
    throw new Error(`register failed (${res.status}): ${JSON.stringify(res.body)}`);
  }
  const token = res.body.accessToken;
  return {
    ...body,
    id: res.body.user.id,
    accessToken: token,
    refreshToken: res.body.refreshToken,
    user: res.body.user,
    get: (path) => api().get(path).set('authorization', `Bearer ${token}`),
    post: (path) => api().post(path).set('authorization', `Bearer ${token}`),
    put: (path) => api().put(path).set('authorization', `Bearer ${token}`),
    patch: (path) => api().patch(path).set('authorization', `Bearer ${token}`),
    del: (path) => api().delete(path).set('authorization', `Bearer ${token}`),
  };
}

export const sampleQuestions = (n = 2) =>
  Array.from({ length: n }, (_, i) => ({
    question_text: `Question number ${i + 1}: which option is right?`,
    options: [`Right ${i}`, `Wrong A ${i}`, `Wrong B ${i}`, `Wrong C ${i}`],
    correct_index: 0,
    explanation: `Because option one is right for question ${i + 1}.`,
    difficulty: 'medium',
    source_reference: `Slide ${i + 1}`,
    time_limit_seconds: 20,
  }));

/** Creates a published quiz owned by `educator` and returns {quiz, questions}. */
export async function makePublishedQuiz(educator, { count = 2, subject = 'Biology' } = {}) {
  const quizRes = await educator
    .post('/api/quizzes')
    .send({ title: 'Test quiz', subject, description: 'A quiz for tests.' });
  if (quizRes.status !== 201) {
    throw new Error(`create quiz failed: ${JSON.stringify(quizRes.body)}`);
  }
  const quiz = quizRes.body;

  const qRes = await educator
    .post(`/api/quizzes/${quiz.id}/questions`)
    .send({ questions: sampleQuestions(count) });
  if (qRes.status !== 201) throw new Error(`add questions failed: ${JSON.stringify(qRes.body)}`);

  const pub = await educator.post(`/api/quizzes/${quiz.id}/publish`).send({});
  if (pub.status !== 200) throw new Error(`publish failed: ${JSON.stringify(pub.body)}`);

  return { quiz: pub.body, questions: qRes.body };
}

/** Host creates a session, students join it. Returns {session, participants}. */
export async function makeLiveSession(educator, quizId, students = []) {
  const res = await educator.post('/api/sessions').send({ quiz_id: quizId });
  if (res.status !== 201) throw new Error(`create session failed: ${JSON.stringify(res.body)}`);
  const session = res.body;
  const participants = [];
  for (const s of students) {
    const j = await s.post('/api/sessions/join').send({ join_code: session.join_code });
    if (j.status !== 201) throw new Error(`join failed: ${JSON.stringify(j.body)}`);
    participants.push(j.body);
  }
  return { session, participants };
}

export const errorCode = (res) => res.body?.error?.code;
