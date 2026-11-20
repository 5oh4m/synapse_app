import { Router } from 'express';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { quizJson, questionJson, redactQuestion } from '../util/serialize.js';
import { str, int, assertUuid, rejectIdentityFields } from '../util/validate.js';
import * as svc from '../services/quiz.service.js';

export const quizRoutes = Router();

quizRoutes.get('/', requireAuth, requireRole('educator'), async (req, res) => {
  res.json((await svc.listQuizzes(req.user.sub)).map(quizJson));
});

/** Any signed-in user may browse published quizzes (practice mode). */
quizRoutes.get('/published', requireAuth, async (_req, res) => {
  res.json((await svc.listPublished()).map(quizJson));
});

quizRoutes.post('/', requireAuth, requireRole('educator'), async (req, res) => {
  rejectIdentityFields(req.body);
  const contentId = req.body?.content_id ?? req.body?.content_item_id ?? null;
  if (contentId !== null) assertUuid(contentId, 'content_id');
  const quiz = await svc.createQuiz({
    ownerId: req.user.sub,
    title: str(req.body, 'title', { required: true, max: 200 }),
    subject: str(req.body, 'subject', { max: 120 }) ?? null,
    description: str(req.body, 'description', { max: 2000 }) ?? '',
    contentId,
  });
  res.status(201).json(quizJson(quiz));
});

quizRoutes.get('/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  res.json(quizJson(await svc.readableQuiz(req.params.id, req.user.sub)));
});

quizRoutes.patch('/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  rejectIdentityFields(req.body);
  const scoring = req.body?.scoring ?? {};
  const quiz = await svc.patchQuiz(req.params.id, req.user.sub, {
    title: str(req.body, 'title', { max: 200 }),
    subject: str(req.body, 'subject', { max: 120 }),
    description: str(req.body, 'description', { max: 2000 }),
    basePoints: int(scoring, 'base_points', { min: 0, max: 100_000 }),
    speedBonusMax: int(scoring, 'speed_bonus_max', { min: 0, max: 100_000 }),
  });
  res.json(quizJson(quiz));
});

quizRoutes.delete('/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  await svc.deleteQuiz(req.params.id, req.user.sub);
  res.status(204).end();
});

quizRoutes.post('/:id/publish', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  res.json(quizJson(await svc.publishQuiz(req.params.id, req.user.sub)));
});

quizRoutes.post('/:id/unpublish', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  res.json(quizJson(await svc.unpublishQuiz(req.params.id, req.user.sub)));
});

/**
 * Owner-or-published, but only the owner gets the answer key.
 *
 * This route used to serve correct_index to anyone once a quiz was published
 * "for practice". Go Live is only offered on published quizzes and every
 * student receives quiz_id in the session payload, so every live game's key
 * was one request away. Everyone else now gets redacted questions, and none at
 * all while the quiz is being played live; practice answers are graded by
 * POST /quizzes/:id/practice/answer instead.
 */
quizRoutes.get('/:id/questions', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  const quiz = await svc.readableQuiz(req.params.id, req.user.sub);
  const rows = (await svc.listQuestions(quiz.id)).map(questionJson);
  if (quiz.owner_id === req.user.sub) return res.json(rows);
  await svc.assertNotLive(quiz.id);
  res.json(rows.map(redactQuestion));
});

/**
 * Grades one practice answer. Stateless: practice never touches scores or the
 * leaderboard. Returns the key for that one question after the player has
 * committed to an answer, which is the same thing a self-marked runner showed.
 */
quizRoutes.post('/:id/practice/answer', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  rejectIdentityFields(req.body);
  const quiz = await svc.readableQuiz(req.params.id, req.user.sub);
  if (quiz.owner_id !== req.user.sub) await svc.assertNotLive(quiz.id);
  assertUuid(req.body?.question_id, 'question_id');
  const selected = int(req.body, 'selected_index', { required: true, min: -1, max: 3 });
  const question = await svc.quizQuestion(quiz.id, req.body.question_id);
  res.json({
    question_id: question.id,
    selected_index: selected,
    is_correct: selected >= 0 && selected === question.correct_index,
    correct_index: question.correct_index,
    explanation: question.explanation ?? '',
  });
});

quizRoutes.post('/:id/questions', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  rejectIdentityFields(req.body);
  const created = await svc.appendQuestions(req.params.id, req.user.sub, req.body?.questions);
  res.status(201).json(created.map(questionJson));
});

quizRoutes.post('/:id/questions/reorder', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  const rows = await svc.reorderQuestions(req.params.id, req.user.sub, req.body?.ordered_ids);
  res.json(rows.map(questionJson));
});
