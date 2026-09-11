// /questions/:id — the question-level routes, all owner-gated.
import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { questionJson } from '../util/serialize.js';
import { assertUuid, rejectIdentityFields } from '../util/validate.js';
import * as svc from '../services/quiz.service.js';

export const questionRoutes = Router();

questionRoutes.get('/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  res.json(questionJson(await svc.ownedQuestion(req.params.id, req.user.sub)));
});

/**
 * Replaces the question in place. The id and the order_index survive, which is
 * what makes "Regenerate" a replacement instead of the duplicate it used to
 * produce (2 questions became 3, two of them sharing order_index 0).
 */
questionRoutes.put('/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  rejectIdentityFields(req.body);
  res.json(questionJson(await svc.replaceQuestion(req.params.id, req.user.sub, req.body)));
});

questionRoutes.delete('/:id', requireAuth, async (req, res) => {
  assertUuid(req.params.id, 'id');
  await svc.deleteQuestion(req.params.id, req.user.sub);
  res.status(204).end();
});
