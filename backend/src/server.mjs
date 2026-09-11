// quizzle reference backend (spec section 6, "Alternative backend").
// Node built-in http for REST + `ws` for the single live-updates socket.
// In-memory store; swap for Postgres/Redis for production. No auth hardening —
// this is a dev/reference server.

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

// --- tiny .env loader ------------------------------------------------------
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.join(__dirname, '..', '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2];
  }
}
const PORT = Number(process.env.PORT || 8787);
const AI = process.env.AI || 'mock';
const ANTHROPIC_KEY = process.env.ANTHROPIC_API_KEY || '';
const ANTHROPIC_MODEL = process.env.ANTHROPIC_MODEL || 'claude-sonnet-5';

// --- store ---------------------------------------------------------------
const db = {
  users: new Map(),
  passwords: new Map(),
  tokens: new Map(),
  content: new Map(),
  quizzes: new Map(),
  questions: new Map(),
  sessions: new Map(),
  sessionQuestions: new Map(),
  participants: new Map(),
  responses: new Map(),
  cumulative: new Map(),
};
const uid = () => crypto.randomUUID();
const now = () => new Date().toISOString();
const JOIN_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const joinCode = (n = 6) =>
  Array.from({ length: n }, () =>
    JOIN_ALPHABET[crypto.randomInt(JOIN_ALPHABET.length)]).join('');

// --- persistence -----------------------------------------------------
// Everything is written to one JSON file on disk, so a registered account,
// its quizzes and scores survive an `npm start` restart, not just a browser
// reload (which already survives, since the store lives on this server, not
// the client). Not a substitute for a real database at scale — see
// backend/README.md — but a big step up from pure in-memory.
const DATA_FILE = path.join(__dirname, '..', 'data.json');

function serializeDb() {
  return {
    users: [...db.users.values()],
    passwords: Object.fromEntries(db.passwords),
    tokens: Object.fromEntries(db.tokens),
    content: [...db.content.values()],
    quizzes: [...db.quizzes.values()],
    questions: [...db.questions.values()],
    sessions: [...db.sessions.values()],
    sessionQuestions: Object.fromEntries(db.sessionQuestions),
    participants: [...db.participants.values()],
    responses: [...db.responses.values()],
    cumulative: [...db.cumulative.values()],
  };
}

function loadDb() {
  if (!fs.existsSync(DATA_FILE)) return false;
  try {
    const raw = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    for (const u of raw.users || []) db.users.set(u.id, u);
    for (const [k, v] of Object.entries(raw.passwords || {})) db.passwords.set(k, v);
    for (const [k, v] of Object.entries(raw.tokens || {})) db.tokens.set(k, v);
    for (const c of raw.content || []) db.content.set(c.id, c);
    for (const q of raw.quizzes || []) db.quizzes.set(q.id, q);
    for (const q of raw.questions || []) db.questions.set(q.id, q);
    for (const s of raw.sessions || []) db.sessions.set(s.id, s);
    for (const [k, v] of Object.entries(raw.sessionQuestions || {})) {
      db.sessionQuestions.set(k, v);
    }
    for (const p of raw.participants || []) db.participants.set(p.id, p);
    for (const r of raw.responses || []) db.responses.set(r.id, r);
    for (const c of raw.cumulative || []) db.cumulative.set(c.studentId, c);
    return true;
  } catch (e) {
    console.error(`Could not read ${DATA_FILE}, starting empty:`, e.message);
    return false;
  }
}

let persistTimer = null;
function schedulePersist() {
  clearTimeout(persistTimer);
  persistTimer = setTimeout(() => {
    try {
      fs.writeFileSync(DATA_FILE, JSON.stringify(serializeDb()));
    } catch (e) {
      console.error('Could not persist data.json:', e.message);
    }
  }, 300);
}

// --- websocket bus -----------------------------------------------------
const wss = new WebSocketServer({ noServer: true });
const sockets = new Set();
function broadcast(channel) {
  schedulePersist();
  const msg = JSON.stringify({ channel });
  for (const ws of sockets) {
    if (ws.readyState === ws.OPEN) ws.send(msg);
  }
}

// --- serializers (must match lib/models/*.dart toJson) --------------
const timeForDifficulty = (d) => (d === 'easy' ? 15 : d === 'hard' ? 30 : 20);

const userJson = (u) => ({
  id: u.id, name: u.name, email: u.email, role: u.role, created_at: u.createdAt,
});
const contentJson = (c) => ({
  id: c.id, owner_id: c.ownerId, title: c.title, subject: c.subject,
  file_type: c.fileType, status: c.status, file_url: c.fileUrl,
  extracted_text: c.extractedText, page_count: c.pageCount, error: c.error,
  created_at: c.createdAt,
});
const quizJson = (q) => ({
  id: q.id, owner_id: q.ownerId, title: q.title, subject: q.subject,
  description: q.description, tags: q.tags, content_item_id: q.contentItemId,
  status: q.status, question_count: countQuestions(q.id),
  scoring: { base_points: q.scoring.basePoints, speed_bonus_max: q.scoring.speedBonusMax },
  created_at: q.createdAt,
});
const questionJson = (q) => ({
  id: q.id, quiz_id: q.quizId, question_text: q.text, options: q.options,
  correct_index: q.correctIndex, explanation: q.explanation,
  difficulty: q.difficulty, source_reference: q.sourceReference,
  order_index: q.orderIndex, time_limit_seconds: q.timeLimitSeconds,
});
const sessionJson = (s) => ({
  id: s.id, quiz_id: s.quizId, quiz_title: s.quizTitle, host_id: s.hostId,
  join_code: s.joinCode, status: s.status,
  current_question_index: s.currentQuestionIndex, total_questions: s.totalQuestions,
  phase: s.phase, question_started_at: s.questionStartedAt,
  question_ends_at: s.questionEndsAt, started_at: s.startedAt,
  ended_at: s.endedAt, allow_late_join: s.allowLateJoin, created_at: s.createdAt,
});
const participantJson = (p) => ({
  id: p.id, session_id: p.sessionId, student_id: p.studentId,
  display_name: p.displayName, joined_at: p.joinedAt, total_score: p.totalScore,
  correct_count: p.correctCount, answered_count: p.answeredCount,
  streak: p.streak, connected: p.connected, last_answered_index: p.lastAnsweredIndex,
});
const responseJson = (r) => ({
  id: r.id, session_id: r.sessionId, student_id: r.studentId,
  question_id: r.questionId, question_index: r.questionIndex,
  selected_index: r.selectedIndex, is_correct: r.isCorrect,
  response_time_ms: r.responseTimeMs, points_awarded: r.pointsAwarded,
  answered_at: r.answeredAt,
});

function countQuestions(quizId) {
  let n = 0;
  for (const q of db.questions.values()) if (q.quizId === quizId) n++;
  return n;
}
function questionsForQuiz(quizId) {
  return [...db.questions.values()]
    .filter((q) => q.quizId === quizId)
    .sort((a, b) => a.orderIndex - b.orderIndex);
}
function participantsForSession(sessionId) {
  return [...db.participants.values()]
    .filter((p) => p.sessionId === sessionId)
    .sort((a, b) => b.totalScore - a.totalScore ||
      new Date(a.joinedAt) - new Date(b.joinedAt));
}
function responsesForSession(sessionId) {
  return [...db.responses.values()].filter((r) => r.sessionId === sessionId);
}

// --- scoring (mirror lib/models/scoring.dart) --------------------------
function pointsFor(scoring, isCorrect, responseTimeMs, timeLimitMs) {
  if (!isCorrect) return 0;
  if (timeLimitMs <= 0) return scoring.basePoints;
  const frac = Math.min(1, Math.max(0, (timeLimitMs - responseTimeMs) / timeLimitMs));
  return scoring.basePoints + Math.round(scoring.speedBonusMax * frac);
}

// --- AI generation ---------------------------------------------------
async function generateQuestions({ source_text, count, difficulty_mix, subject, title, quiz_id }) {
  const diffs = resolveDifficulties(difficulty_mix || {}, count);
  if (AI === 'anthropic' && ANTHROPIC_KEY) {
    try {
      return await generateWithClaude({ source_text, count, diffs, subject, title, quiz_id });
    } catch (e) {
      // Fall back to mock so a bad key / quota never hard-blocks a demo.
      console.error('Claude generation failed, using mock:', e.message);
    }
  }
  return mockGenerate({ source_text, diffs, subject: subject || title, quiz_id });
}

function resolveDifficulties(mix, count) {
  const total = Object.values(mix).reduce((a, b) => a + Number(b || 0), 0);
  if (total <= 0) return Array.from({ length: count }, () => 'medium');
  const out = [];
  for (const [d, w] of Object.entries(mix)) {
    const n = Math.round((Number(w) / total) * count);
    for (let i = 0; i < n; i++) out.push(d);
  }
  while (out.length < count) out.push('medium');
  return out.slice(0, count);
}

function mockGenerate({ source_text, diffs, subject, quiz_id }) {
  const sentences = String(source_text || '')
    .replace(/\s+/g, ' ')
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 24 && s.split(' ').length <= 34);
  const stop = new Set(['the', 'and', 'for', 'are', 'with', 'from', 'that', 'this',
    'which', 'their', 'they', 'have', 'been', 'were', 'into', 'these', 'such', 'also']);
  const questions = [];
  for (let i = 0; i < diffs.length; i++) {
    const s = sentences[i % Math.max(1, sentences.length)] || `Key idea about ${subject}`;
    const words = s.split(/\s+/)
      .map((w) => w.replace(/[^A-Za-z0-9-]/g, ''))
      .filter((w) => w.length >= 4 && !stop.has(w.toLowerCase()));
    const answer = words.sort((a, b) => b.length - a.length)[0] || subject || 'concept';
    const pool = [...new Set(sentences.join(' ').split(/\s+/)
      .map((w) => w.replace(/[^A-Za-z0-9-]/g, ''))
      .filter((w) => w.length >= 4 && w.toLowerCase() !== answer.toLowerCase()
        && !stop.has(w.toLowerCase())))];
    shuffle(pool);
    const opts = [answer, ...pool.slice(0, 3)];
    while (opts.length < 4) opts.push(['none of these', 'all of these', 'not stated'][opts.length - 1] || 'other');
    shuffle(opts);
    questions.push({
      question: `Fill in the blank: "${s.replace(answer, '_____').slice(0, 200)}"`,
      options: opts.slice(0, 4),
      correct_index: opts.indexOf(answer) < 0 ? 0 : opts.indexOf(answer),
      explanation: `The material states: "${s.slice(0, 160)}"`,
      difficulty: diffs[i],
      source_reference: `Page ${1 + Math.floor(i / 3)}`,
    });
  }
  return questions;
}
function shuffle(a) {
  for (let i = a.length - 1; i > 0; i--) {
    const j = crypto.randomInt(i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
}

async function generateWithClaude({ source_text, count, diffs, subject, title }) {
  const mix = diffs.reduce((m, d) => ((m[d] = (m[d] || 0) + 1), m), {});
  const prompt =
`You are writing a multiple-choice quiz for the subject "${subject || title}".
Create exactly ${count} questions, difficulty counts: ${JSON.stringify(mix)}.
Base every question strictly on this material:
"""
${String(source_text).slice(0, 24000)}
"""
Return ONLY JSON: {"questions":[{"question":string,"options":[s,s,s,s],
"correct_index":0-3,"explanation":string,"difficulty":"easy|medium|hard",
"source_reference":string}]}. Exactly 4 distinct non-empty options.`;
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': ANTHROPIC_KEY,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: ANTHROPIC_MODEL,
      max_tokens: 4096,
      messages: [{ role: 'user', content: prompt }],
    }),
  });
  if (!res.ok) throw new Error(`Anthropic ${res.status}`);
  const data = await res.json();
  const text = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('');
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  const parsed = JSON.parse(text.slice(start, end + 1));
  return parsed.questions || parsed;
}

// Validate against the spec schema; throws on malformed output.
function validateQuestions(raw, expected) {
  const list = Array.isArray(raw) ? raw : raw?.questions;
  if (!Array.isArray(list) || list.length === 0) throw new Error('AI returned no questions.');
  return list.map((row, i) => {
    const text = String(row.question ?? row.question_text ?? '').trim();
    const options = (row.options || []).map((o) => String(o).trim());
    const ci = row.correct_index;
    if (!text) throw new Error(`Question ${i + 1} has no text.`);
    if (options.length !== 4 || options.some((o) => !o))
      throw new Error(`Question ${i + 1} needs exactly 4 non-empty options.`);
    if (!Number.isInteger(ci) || ci < 0 || ci > 3)
      throw new Error(`Question ${i + 1} has an invalid correct_index.`);
    if (new Set(options).size !== options.length)
      throw new Error(`Question ${i + 1} has duplicate options.`);
    return {
      question_text: text, options, correct_index: ci,
      explanation: String(row.explanation ?? '').trim(),
      difficulty: ['easy', 'medium', 'hard'].includes(row.difficulty) ? row.difficulty : 'medium',
      source_reference: String(row.source_reference ?? '').trim(),
    };
  });
}

// --- session engine ---------------------------------------------------
function advanceTo(session, index) {
  const qs = db.sessionQuestions.get(session.id);
  const limit = qs[index].timeLimitSeconds;
  const t = new Date();
  session.status = 'active';
  session.currentQuestionIndex = index;
  session.phase = 'asking';
  session.questionStartedAt = t.toISOString();
  session.questionEndsAt = new Date(t.getTime() + limit * 1000).toISOString();
  session.startedAt = session.startedAt || t.toISOString();
  broadcast(`session:${session.id}`);
}
function autoZeroMissing(session) {
  const idx = session.currentQuestionIndex;
  const qs = db.sessionQuestions.get(session.id);
  if (idx < 0 || idx >= qs.length) return;
  for (const p of participantsForSession(session.id)) {
    const answered = [...db.responses.values()].some(
      (r) => r.sessionId === session.id && r.studentId === p.studentId && r.questionIndex === idx);
    if (answered) continue;
    const r = {
      id: uid(), sessionId: session.id, studentId: p.studentId,
      questionId: qs[idx].id, questionIndex: idx, selectedIndex: -1,
      isCorrect: false, responseTimeMs: qs[idx].timeLimitSeconds * 1000,
      pointsAwarded: 0, answeredAt: now(),
    };
    db.responses.set(r.id, r);
    p.answeredCount += 1;
    p.streak = 0;
    p.lastAnsweredIndex = idx;
  }
}
function endSession(session) {
  if (session.status === 'ended') return;
  if (session.status === 'active') autoZeroMissing(session);
  session.status = 'ended';
  session.phase = 'revealing';
  session.endedAt = now();
  for (const p of participantsForSession(session.id)) {
    const cum = db.cumulative.get(p.studentId) ||
      { studentId: p.studentId, name: p.displayName, points: 0, quizzes: 0, correct: 0, answered: 0 };
    cum.points += p.totalScore;
    cum.quizzes += 1;
    cum.correct += p.correctCount;
    cum.answered += p.answeredCount;
    db.cumulative.set(p.studentId, cum);
  }
  broadcast(`session:${session.id}`);
  broadcast('leaderboard');
}

// --- routing -------------------------------------------------------------
const routes = [];
const on = (method, pattern, handler) => routes.push({ method, parts: pattern.split('/').filter(Boolean), handler });

function match(routeParts, urlParts) {
  if (routeParts.length !== urlParts.length) return null;
  const params = {};
  for (let i = 0; i < routeParts.length; i++) {
    if (routeParts[i].startsWith(':')) params[routeParts[i].slice(1)] = decodeURIComponent(urlParts[i]);
    else if (routeParts[i] !== urlParts[i]) return null;
  }
  return params;
}

const ok = (res, body, code = 200) => {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body ?? {}));
};
const err = (res, message, code = 400) => ok(res, { error: message }, code);

// auth
on('POST', '/auth/register', (req, res, p, body) => {
  const email = String(body.email || '').trim().toLowerCase();
  if (db.passwords.has(email)) return err(res, 'An account with that email already exists.');
  if (String(body.password || '').length < 6) return err(res, 'Password must be at least 6 characters.');
  const u = {
    id: uid(), name: (body.name || email.split('@')[0]).trim(),
    email, role: body.role === 'educator' ? 'educator' : 'student', createdAt: now(),
  };
  db.users.set(u.id, u);
  db.passwords.set(email, body.password);
  const token = uid();
  db.tokens.set(token, u.id);
  schedulePersist();
  ok(res, { token, user: userJson(u) });
});
on('POST', '/auth/login', (req, res, p, body) => {
  const email = String(body.email || '').trim().toLowerCase();
  if (db.passwords.get(email) !== body.password) return err(res, 'Wrong email or password.', 401);
  const u = [...db.users.values()].find((x) => x.email === email);
  const token = uid();
  db.tokens.set(token, u.id);
  schedulePersist();
  ok(res, { token, user: userJson(u) });
});
on('POST', '/auth/logout', (req, res) => {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  if (db.tokens.delete(token)) schedulePersist();
  ok(res, {});
});
on('GET', '/auth/me', (req, res) => {
  const u = currentUser(req);
  return u ? ok(res, { user: userJson(u) }) : err(res, 'Not signed in.', 401);
});
on('PUT', '/auth/profile', (req, res, p, body) => {
  const u = currentUser(req);
  if (!u) return err(res, 'Not signed in.', 401);
  if (body.name) u.name = String(body.name);
  schedulePersist();
  ok(res, { user: userJson(u) });
});
function currentUser(req) {
  const auth = req.headers.authorization || '';
  const id = db.tokens.get(auth.replace('Bearer ', ''));
  return id ? db.users.get(id) : null;
}

// content
on('GET', '/content', (req, res, p, body, query) => {
  const ownerId = query.get('owner_id');
  ok(res, [...db.content.values()]
    .filter((c) => c.ownerId === ownerId)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(contentJson));
});
on('GET', '/content/:id', (req, res, p) => {
  const c = db.content.get(p.id);
  return c ? ok(res, contentJson(c)) : err(res, 'Content not found.', 404);
});
on('POST', '/content', (req, res, p, body) => {
  const text = String(body.raw_text || '').trim();
  const c = {
    id: uid(), ownerId: body.owner_id, title: (body.title || body.file_name || 'Untitled').trim(),
    subject: body.subject || null, fileType: body.source_type || 'text',
    status: text.length < 40 && body.source_type !== 'image' ? 'failed' : 'ready',
    fileUrl: body.file_name || null, extractedText: text,
    pageCount: body.page_count || 1,
    error: text.length < 40 && body.source_type !== 'image'
      ? 'Could not extract enough text. Paste the text manually.' : null,
    createdAt: now(),
  };
  db.content.set(c.id, c);
  broadcast('content');
  ok(res, contentJson(c));
});
on('DELETE', '/content/:id', (req, res, p) => {
  db.content.delete(p.id);
  broadcast('content');
  ok(res, {});
});

// quizzes
on('GET', '/quizzes', (req, res, p, body, query) => {
  const ownerId = query.get('owner_id');
  ok(res, [...db.quizzes.values()]
    .filter((q) => q.ownerId === ownerId)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(quizJson));
});
on('GET', '/quizzes/published', (req, res) => {
  ok(res, [...db.quizzes.values()].filter((q) => q.status === 'published').map(quizJson));
});
on('GET', '/quizzes/:id', (req, res, p) => {
  const q = db.quizzes.get(p.id);
  return q ? ok(res, quizJson(q)) : err(res, 'Quiz not found.', 404);
});
on('GET', '/quizzes/:id/questions', (req, res, p) => {
  ok(res, questionsForQuiz(p.id).map(questionJson));
});
on('POST', '/quizzes', (req, res, p, body) => {
  const q = {
    id: uid(), ownerId: body.owner_id, title: (body.title || 'Untitled quiz').trim(),
    subject: body.subject || '', description: '', tags: [],
    contentItemId: body.content_item_id || null, status: 'draft',
    scoring: { basePoints: 500, speedBonusMax: 500 }, createdAt: now(),
  };
  db.quizzes.set(q.id, q);
  broadcast('quizzes');
  ok(res, quizJson(q));
});
on('PUT', '/quizzes/:id', (req, res, p, body) => {
  const q = db.quizzes.get(p.id);
  if (!q) return err(res, 'Quiz not found.', 404);
  q.title = body.title ?? q.title;
  q.subject = body.subject ?? q.subject;
  q.description = body.description ?? q.description;
  q.tags = body.tags ?? q.tags;
  if (body.scoring) {
    q.scoring.basePoints = body.scoring.base_points ?? q.scoring.basePoints;
    q.scoring.speedBonusMax = body.scoring.speed_bonus_max ?? q.scoring.speedBonusMax;
  }
  broadcast('quizzes');
  ok(res, {});
});
on('POST', '/quizzes/:id/publish', (req, res, p) => {
  const q = db.quizzes.get(p.id);
  if (!q) return err(res, 'Quiz not found.', 404);
  const qs = questionsForQuiz(p.id);
  if (qs.length < 2) return err(res, 'Add at least 2 questions before publishing.');
  q.status = 'published';
  broadcast('quizzes');
  ok(res, {});
});
on('POST', '/quizzes/:id/unpublish', (req, res, p) => {
  const q = db.quizzes.get(p.id);
  if (q) { q.status = 'draft'; broadcast('quizzes'); }
  ok(res, {});
});
on('DELETE', '/quizzes/:id', (req, res, p) => {
  db.quizzes.delete(p.id);
  for (const [k, v] of db.questions) if (v.quizId === p.id) db.questions.delete(k);
  broadcast('quizzes');
  broadcast(`questions:${p.id}`);
  ok(res, {});
});
on('POST', '/quizzes/:id/questions', (req, res, p, body) => {
  let base = countQuestions(p.id);
  for (const raw of body.questions || []) {
    const id = uid();
    db.questions.set(id, {
      id, quizId: p.id, text: raw.question_text || raw.question || 'Question',
      options: raw.options || ['A', 'B', 'C', 'D'],
      correctIndex: raw.correct_index ?? 0, explanation: raw.explanation || '',
      difficulty: raw.difficulty || 'medium', sourceReference: raw.source_reference || '',
      orderIndex: base++, timeLimitSeconds: raw.time_limit_seconds || timeForDifficulty(raw.difficulty),
    });
  }
  broadcast(`questions:${p.id}`);
  broadcast('quizzes');
  ok(res, {});
});
on('PUT', '/questions/:id', (req, res, p, body) => {
  const q = db.questions.get(p.id);
  if (!q) return err(res, 'Question not found.', 404);
  q.text = body.question_text ?? q.text;
  q.options = body.options ?? q.options;
  q.correctIndex = body.correct_index ?? q.correctIndex;
  q.explanation = body.explanation ?? q.explanation;
  q.difficulty = body.difficulty ?? q.difficulty;
  q.timeLimitSeconds = body.time_limit_seconds ?? q.timeLimitSeconds;
  if (body.order_index != null) q.orderIndex = body.order_index;
  broadcast(`questions:${q.quizId}`);
  ok(res, {});
});
on('DELETE', '/questions/:id', (req, res, p, body, query) => {
  const q = db.questions.get(p.id);
  const quizId = query.get('quiz_id') || q?.quizId;
  db.questions.delete(p.id);
  questionsForQuiz(quizId).forEach((x, i) => { x.orderIndex = i; });
  broadcast(`questions:${quizId}`);
  broadcast('quizzes');
  ok(res, {});
});
on('POST', '/quizzes/:id/questions/reorder', (req, res, p, body) => {
  (body.ordered_ids || []).forEach((id, i) => {
    const q = db.questions.get(id);
    if (q) q.orderIndex = i;
  });
  broadcast(`questions:${p.id}`);
  ok(res, {});
});

// generation
on('POST', '/generate', async (req, res, p, body) => {
  try {
    const raw = await generateQuestions(body);
    const validated = validateQuestions(raw, body.count);
    ok(res, { questions: validated });
  } catch (e) {
    err(res, e.message || 'Generation failed.', 502);
  }
});

// sessions
on('POST', '/sessions', (req, res, p, body) => {
  const quiz = db.quizzes.get(body.quiz_id);
  if (!quiz) return err(res, 'Quiz not found.', 404);
  const qs = questionsForQuiz(quiz.id);
  if (qs.length === 0) return err(res, 'This quiz has no questions.');
  let code = joinCode();
  while ([...db.sessions.values()].some((s) => s.joinCode === code && s.status !== 'ended')) code = joinCode();
  const s = {
    id: uid(), quizId: quiz.id, quizTitle: quiz.title, hostId: body.host_id,
    joinCode: code, status: 'lobby', currentQuestionIndex: -1,
    totalQuestions: qs.length, phase: 'asking', questionStartedAt: null,
    questionEndsAt: null, startedAt: null, endedAt: null, allowLateJoin: true,
    createdAt: now(),
  };
  db.sessions.set(s.id, s);
  db.sessionQuestions.set(s.id, qs.map((q) => ({ ...q })));
  broadcast(`session:${s.id}`);
  ok(res, sessionJson(s));
});
on('GET', '/sessions/:id', (req, res, p) => {
  const s = db.sessions.get(p.id);
  return s ? ok(res, sessionJson(s)) : err(res, 'Session not found.', 404);
});
on('GET', '/sessions/by-code/:code', (req, res, p) => {
  const code = String(p.code || '').toUpperCase();
  const s = [...db.sessions.values()].find((x) => x.joinCode === code && x.status !== 'ended');
  return s ? ok(res, sessionJson(s)) : err(res, 'No live session with that code.', 404);
});
on('GET', '/sessions/:id/participants', (req, res, p) => {
  ok(res, participantsForSession(p.id).map(participantJson));
});
on('GET', '/sessions/:id/responses', (req, res, p) => {
  ok(res, responsesForSession(p.id).map(responseJson));
});
on('GET', '/sessions/:id/questions', (req, res, p) => {
  ok(res, (db.sessionQuestions.get(p.id) || []).map(questionJson));
});
on('GET', '/sessions/:id/questions/:index/public', (req, res, p) => {
  const qs = db.sessionQuestions.get(p.id);
  const s = db.sessions.get(p.id);
  const i = Number(p.index);
  if (!qs || !s || i < 0 || i >= qs.length) return err(res, 'Not found.', 404);
  const q = qs[i];
  const revealed = s.status === 'ended' ||
    (s.currentQuestionIndex === i && s.phase === 'revealing');
  ok(res, questionJson(revealed ? q : { ...q, correctIndex: -1, explanation: '' }));
});
on('POST', '/sessions/join', (req, res, p, body) => {
  const code = String(body.join_code || '').toUpperCase();
  const s = [...db.sessions.values()].find((x) => x.joinCode === code && x.status !== 'ended');
  if (!s) return err(res, 'No live session with that code.', 404);
  const student = body.student || {};
  let existing = [...db.participants.values()].find(
    (x) => x.sessionId === s.id && x.studentId === student.id);
  if (existing) {
    existing.connected = true;
    broadcast(`session:${s.id}`);
    return ok(res, participantJson(existing));
  }
  if (s.status !== 'lobby' && !s.allowLateJoin) return err(res, 'This session has already started.');
  const part = {
    id: uid(), sessionId: s.id, studentId: student.id,
    displayName: student.name || 'Player', joinedAt: now(), totalScore: 0,
    correctCount: 0, answeredCount: 0, streak: 0, connected: true, lastAnsweredIndex: -1,
  };
  db.participants.set(part.id, part);
  broadcast(`session:${s.id}`);
  ok(res, participantJson(part));
});
on('POST', '/sessions/:id/connected', (req, res, p, body) => {
  const part = [...db.participants.values()].find(
    (x) => x.sessionId === p.id && x.studentId === body.student_id);
  if (part) { part.connected = !!body.connected; broadcast(`session:${p.id}`); }
  ok(res, {});
});
on('POST', '/sessions/:id/start', (req, res, p) => {
  const s = db.sessions.get(p.id);
  if (!s) return err(res, 'Session not found.', 404);
  if (s.status === 'lobby') advanceTo(s, 0);
  ok(res, {});
});
on('POST', '/sessions/:id/reveal', (req, res, p) => {
  const s = db.sessions.get(p.id);
  if (!s) return err(res, 'Session not found.', 404);
  if (s.status === 'active') {
    s.phase = 'revealing';
    autoZeroMissing(s);
    broadcast(`session:${p.id}`);
  }
  ok(res, {});
});
on('POST', '/sessions/:id/next', (req, res, p) => {
  const s = db.sessions.get(p.id);
  if (!s) return err(res, 'Session not found.', 404);
  if (s.status !== 'active') return ok(res, {});
  const next = s.currentQuestionIndex + 1;
  if (next >= s.totalQuestions) endSession(s);
  else advanceTo(s, next);
  ok(res, {});
});
on('POST', '/sessions/:id/end', (req, res, p) => {
  const s = db.sessions.get(p.id);
  if (s) endSession(s);
  ok(res, {});
});
on('POST', '/sessions/:id/answer', (req, res, p, body) => {
  const s = db.sessions.get(p.id);
  if (!s) return err(res, 'Session not found.', 404);
  const idx = body.question_index;
  if (idx !== s.currentQuestionIndex || s.phase !== 'asking' || s.status !== 'active')
    return err(res, 'That question is not accepting answers.');
  const part = [...db.participants.values()].find(
    (x) => x.sessionId === s.id && x.studentId === body.student_id);
  if (!part) return err(res, 'Join the session first.');
  const prior = [...db.responses.values()].find(
    (r) => r.sessionId === s.id && r.studentId === body.student_id && r.questionIndex === idx);
  if (prior) return ok(res, responseJson(prior));

  const qs = db.sessionQuestions.get(s.id);
  const question = qs[idx];
  const limitMs = question.timeLimitSeconds * 1000;
  const clamped = Math.min(Math.max(0, body.response_time_ms || 0), limitMs);
  const isCorrect = body.selected_index >= 0 && body.selected_index === question.correctIndex;
  const quiz = db.quizzes.get(s.quizId);
  const scoring = quiz ? quiz.scoring : { basePoints: 500, speedBonusMax: 500 };
  const past = (body.response_time_ms || 0) > limitMs;
  const points = past ? 0 : pointsFor(scoring, isCorrect, clamped, limitMs);
  const r = {
    id: uid(), sessionId: s.id, studentId: body.student_id,
    questionId: question.id, questionIndex: idx, selectedIndex: body.selected_index,
    isCorrect, responseTimeMs: clamped, pointsAwarded: points, answeredAt: now(),
  };
  db.responses.set(r.id, r);
  part.totalScore += points;
  part.correctCount += isCorrect ? 1 : 0;
  part.answeredCount += 1;
  part.streak = isCorrect ? part.streak + 1 : 0;
  part.lastAnsweredIndex = idx;
  broadcast(`session:${s.id}`);
  ok(res, responseJson(r));
});

// leaderboard + analytics
on('GET', '/leaderboard/global', (req, res) => {
  const entries = [...db.cumulative.values()]
    .map((c) => ({
      student_id: c.studentId, display_name: c.name, points: c.points,
      quizzes_played: c.quizzes, correct_rate: c.answered ? c.correct / c.answered : 0,
    }))
    .sort((a, b) => b.points - a.points)
    .map((e, i) => ({ ...e, rank: i + 1 }));
  ok(res, entries);
});
on('GET', '/analytics/quiz/:id', (req, res, p) => {
  const sessions = [...db.sessions.values()].filter((s) => s.quizId === p.id && s.status === 'ended');
  const ids = new Set(sessions.map((s) => s.id));
  const responses = [...db.responses.values()].filter((r) => ids.has(r.sessionId));
  const parts = [...db.participants.values()].filter((x) => ids.has(x.sessionId));
  const questions = questionsForQuiz(p.id);
  const question_stats = questions.map((q) => {
    const rs = responses.filter((r) => r.questionId === q.id);
    return {
      question_id: q.id, text: q.text, order_index: q.orderIndex,
      answers: rs.filter((r) => r.selectedIndex >= 0).length,
      correct: rs.filter((r) => r.isCorrect).length,
    };
  });
  const totalAns = responses.filter((r) => r.selectedIndex >= 0).length;
  const totalCorrect = responses.filter((r) => r.isCorrect).length;
  ok(res, {
    sessions_run: sessions.length,
    participants: parts.length,
    average_score: parts.length ? parts.reduce((a, b) => a + b.totalScore, 0) / parts.length : 0,
    average_correct_rate: totalAns ? totalCorrect / totalAns : 0,
    completion_rate: parts.length && questions.length
      ? parts.reduce((a, b) => a + b.answeredCount / questions.length, 0) / parts.length : 0,
    question_stats,
  });
});
on('GET', '/analytics/student/:id', (req, res, p) => {
  const out = [];
  for (const s of [...db.sessions.values()].filter((x) => x.status === 'ended')) {
    const ranked = [...db.participants.values()]
      .filter((x) => x.sessionId === s.id)
      .sort((a, b) => b.totalScore - a.totalScore);
    const i = ranked.findIndex((x) => x.studentId === p.id);
    if (i === -1) continue;
    out.push({
      session_id: s.id, quiz_title: s.quizTitle, score: ranked[i].totalScore,
      rank: i + 1, played_at: s.endedAt || s.createdAt,
      correct: ranked[i].correctCount, total: s.totalQuestions,
    });
  }
  out.sort((a, b) => new Date(b.played_at) - new Date(a.played_at));
  ok(res, out);
});

// --- http server -------------------------------------------------------
const server = http.createServer((req, res) => {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-headers', 'content-type,authorization');
  res.setHeader('access-control-allow-methods', 'GET,POST,PUT,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const url = new URL(req.url, 'http://x');
  if (process.env.LOG !== '0') console.log(req.method, url.pathname);
  if (url.pathname === '/' || url.pathname === '/health') return ok(res, { ok: true, ai: AI });
  const urlParts = url.pathname.split('/').filter(Boolean);

  let chunks = '';
  req.on('data', (c) => (chunks += c));
  req.on('end', async () => {
    let body = {};
    if (chunks) { try { body = JSON.parse(chunks); } catch { body = {}; } }
    for (const r of routes) {
      if (r.method !== req.method) continue;
      const params = match(r.parts, urlParts);
      if (!params) continue;
      try {
        await r.handler(req, res, params, body, url.searchParams);
      } catch (e) {
        console.error(e);
        if (!res.headersSent) err(res, 'Internal error', 500);
      }
      return;
    }
    err(res, `No route for ${req.method} ${url.pathname}`, 404);
  });
});

server.on('upgrade', (req, socket, head) => {
  if (new URL(req.url, 'http://x').pathname !== '/ws') return socket.destroy();
  wss.handleUpgrade(req, socket, head, (ws) => {
    sockets.add(ws);
    ws.on('close', () => sockets.delete(ws));
    ws.on('error', () => sockets.delete(ws));
    ws.send(JSON.stringify({ channel: 'hello' }));
  });
});

// Auto-reveal a question when its timer expires, even if the host walks away.
setInterval(() => {
  const t = Date.now();
  for (const s of db.sessions.values()) {
    if (s.status === 'active' && s.phase === 'asking' && s.questionEndsAt &&
        new Date(s.questionEndsAt).getTime() <= t) {
      s.phase = 'revealing';
      autoZeroMissing(s);
      broadcast(`session:${s.id}`);
    }
  }
}, 1000);

const restored = loadDb();

server.listen(PORT, () => {
  console.log(
    `quizzle backend on http://localhost:${PORT}  (AI=${AI})` +
      (restored ? `  [restored ${db.users.size} account(s) from data.json]` : ''),
  );
});
