import { Router } from 'express';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { quizJson, questionJson } from '../util/serialize.js';
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
 * Owner-or-published. This carries the answer key, which is correct: practice
 * mode is self-marked and a published quiz is public by the educator's choice.
 * The live-session key lives behind the host-only session endpoint instead.
 */
quizRoutes.get('/:id/questions', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  await svc.readableQuiz(req.params.id, req.user.sub);
  res.json((await svc.listQuestions(req.params.id)).map(questionJson));
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
