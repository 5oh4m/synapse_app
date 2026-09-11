// Live sessions.
//
// Authorization map (docs/API.md):
//   POST   /sessions                      educator, becomes host
//   GET    /sessions/:id                  host or participant (participant gets redacted)
//   GET    /sessions/by-code/:code        any signed-in user, minimal fields
//   POST   /sessions/join                 student
//   GET    /sessions/:id/participants     host or participant
//   GET    /sessions/:id/questions        HOST ONLY  <- the answer key
//   GET    /sessions/:id/current-question host or participant, redacted until reveal
//   POST   /sessions/:id/answer           participant
//   POST   /sessions/:id/{start,reveal,next,end}  HOST ONLY
//   GET    /sessions/:id/results          host or participant
import { Router } from 'express';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { notFound, validation } from '../errors.js';
import {
  sessionJson,
  participantJson,
  sessionQuestionJson,
  redactQuestion,
  responseJson,
} from '../util/serialize.js';
import { assertUuid, str, int, rejectIdentityFields } from '../util/validate.js';
import * as svc from '../services/session.service.js';
import * as q from '../services/session.queries.js';

export const sessionRoutes = Router();

/** Loads the session and the caller's relationship to it, or 404s. */
async function access(req) {
  assertUuid(req.params.id, 'id');
  const a = await q.getSessionAccess(req.params.id, req.user.sub);
  if (!a) throw notFound('Session not found.');
  return a;
}

/** Host or participant. Anyone else gets 404, not 403. */
async function requireMember(req) {
  const a = await access(req);
  if (!a.isHost && !a.participantId) throw notFound('Session not found.');
  return a;
}

/**
 * Host only. A student hitting a host control gets the same 404 as a stranger:
 * the previous build had no check here at all, so any client could start,
 * reveal, advance or end anybody's game.
 */
async function requireHost(req) {
  const a = await access(req);
  if (!a.isHost) throw notFound('Session not found.');
  return a;
}

sessionRoutes.post('/', requireAuth, requireRole('educator'), async (req, res) => {
  rejectIdentityFields(req.body);
  const quizId = req.body?.quiz_id;
  assertUuid(quizId, 'quiz_id');
  const session = await svc.createSession({ quizId, hostId: req.user.sub });
  res.status(201).json(sessionJson(session));
});

/** Minimal shape on purpose: a join code must not expose the roster. */
sessionRoutes.get('/by-code/:code', requireAuth, async (req, res) => {
  const code = str(req.params, 'code', { required: true, max: 12 });
  const session = await q.getSessionByCode(code);
  if (!session || session.status === 'ended') throw notFound('No live session with that code.');
  res.json({
    id: session.id,
    quiz_title: session.quiz_title,
    status: session.status,
    question_count: session.total_questions,
  });
});

sessionRoutes.post('/join', requireAuth, requireRole('student'), async (req, res) => {
  rejectIdentityFields(req.body);
  const joinCode = str(req.body, 'join_code', { required: true, max: 12 });
  // Identity is the token's, never the body's: the old endpoint took
  // `body.student` and would happily enrol somebody else.
  const { session, participant } = await svc.joinSession({ joinCode, user: req.user });
  res.status(201).json({ ...participantJson(participant), session: sessionJson(session) });
});

sessionRoutes.get('/:id', requireAuth, async (req, res) => {
  const a = await requireMember(req);
  const body = sessionJson(a.session);
  if (a.isHost) return res.json({ ...body, role: 'host' });
  // Participant view: same state machine, no host-side extras.
  return res.json({ ...body, role: 'participant', participant_id: a.participantId });
});

sessionRoutes.get('/:id/participants', requireAuth, async (req, res) => {
  const a = await requireMember(req);
  res.json((await q.listParticipants(a.session.id)).map(participantJson));
});

/** HOST ONLY — full answer key. */
sessionRoutes.get('/:id/questions', requireAuth, async (req, res) => {
  const a = await requireHost(req);
  res.json((await q.listSessionQuestions(a.session.id)).map(sessionQuestionJson));
});

/** Redacted until the question is revealed (or the session has ended). */
sessionRoutes.get('/:id/current-question', requireAuth, async (req, res) => {
  const a = await requireMember(req);
  const s = a.session;
  const index = req.query.index === undefined ? s.current_question_index : Number(req.query.index);
  if (!Number.isInteger(index) || index < 0) {
    return res.json({ question: null, phase: s.phase, current_question_index: s.current_question_index });
  }
  const row = await q.getSessionQuestion(s.id, index);
  if (!row) throw notFound('That question is not in this session.');

  const revealed =
    s.status === 'ended' ||
    index < s.current_question_index ||
    (index === s.current_question_index && s.phase === 'revealing');
  // The host may see the key at any time; students only after reveal.
  const showKey = a.isHost || revealed;
  const json = sessionQuestionJson(row);

  return res.json({
    question: showKey ? json : redactQuestion(json),
    revealed,
    phase: s.phase,
    current_question_index: s.current_question_index,
    question_started_at: s.question_started_at,
    question_ends_at: s.question_ends_at,
    distribution: revealed ? await q.distribution(s.id, index) : null,
  });
});

sessionRoutes.post('/:id/answer', requireAuth, async (req, res) => {
  const a = await requireMember(req);
  if (!a.participantId) throw notFound('Join the session before answering.');
  // Identity from the body is refused outright (docs/API.md rule 1); timing
  // from the body is dropped before anything can read it (rule 2).
  rejectIdentityFields(req.body);
  const ignoredFields = svc.stripClientTiming(req.body);

  const selectedIndex = svc.requireSelectedIndex(req.body);
  const clientQuestionIndex = int(req.body, 'question_index', { min: 0, max: 10_000 });

  const out = await svc.submitAnswer({
    sessionId: a.session.id,
    // Never req.body: the old endpoint took body.student_id and would score an
    // answer against whoever the caller named.
    userId: req.user.sub,
    selectedIndex,
    clientQuestionIndex,
  });

  // Double submit: the first result, 200, unchanged. A fresh score is 201.
  res.status(out.scored ? 201 : 200).json({
    ...responseJson({ ...out.response, user_id: req.user.sub }),
    scored: out.scored,
    rescored: false,
    ignored_fields: ignoredFields,
  });
});

sessionRoutes.post('/:id/start', requireAuth, async (req, res) => {
  const a = await requireHost(req);
  res.json(sessionJson(await svc.startSession(a.session.id)));
});

sessionRoutes.post('/:id/reveal', requireAuth, async (req, res) => {
  const a = await requireHost(req);
  res.json(sessionJson(await svc.revealCurrent(a.session.id, { reason: 'host' })));
});

sessionRoutes.post('/:id/next', requireAuth, async (req, res) => {
  const a = await requireHost(req);
  res.json(sessionJson(await svc.nextQuestion(a.session.id)));
});

sessionRoutes.post('/:id/end', requireAuth, async (req, res) => {
  const a = await requireHost(req);
  res.json(sessionJson(await svc.endSession(a.session.id)));
});

/** Convenience for the lobby / reconnect screen. */
sessionRoutes.post('/:id/connected', requireAuth, async (req, res) => {
  const a = await requireMember(req);
  if (!a.participantId) throw notFound('You are not in that session.');
  if (typeof req.body?.connected !== 'boolean') {
    throw validation('connected must be true or false.', 'connected');
  }
  const row = await svc.setConnected({
    sessionId: a.session.id,
    userId: req.user.sub,
    connected: req.body.connected,
  });
  res.json(participantJson(row));
});

sessionRoutes.get('/:id/results', requireAuth, async (req, res) => {
  const a = await requireMember(req);
  const out = await svc.sessionResults({
    sessionId: a.session.id,
    participantId: a.participantId,
  });
  res.json({
    session: sessionJson(out.session),
    scoreboard: out.scoreboard,
    totals: out.totals,
    my_participant_id: out.my_participant_id,
    my_breakdown: out.my_breakdown,
  });
});

/** Host-only raw responses, for the live analytics panel. */
sessionRoutes.get('/:id/responses', requireAuth, async (req, res) => {
  const a = await requireHost(req);
  res.json((await q.listResponses(a.session.id)).map(responseJson));
});
