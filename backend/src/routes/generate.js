import { Router } from 'express';
import { one } from '../db/pool.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { generateLimiter } from '../middleware/rate-limit.js';
import { notFound, conflict } from '../errors.js';
import { int, str, assertUuid, rejectIdentityFields } from '../util/validate.js';
import { generate, assertGeneratableText } from '../services/ai.service.js';

export const generateRoutes = Router();

/**
 * 20/hour per user. The limiter keys on req.user.sub, so it runs after
 * requireAuth.
 */
generateRoutes.post(
  '/',
  requireAuth,
  requireRole('educator'),
  generateLimiter,
  async (req, res) => {
    rejectIdentityFields(req.body);
    const count = int(req.body, 'count', { min: 1, max: 30, def: 5 });

    let sourceText = str(req.body, 'source_text', { max: 2_000_000, trim: false });
    let subject = str(req.body, 'subject', { max: 120 });

    const contentId = req.body?.content_id ?? null;
    if (contentId) {
      assertUuid(contentId, 'content_id');
      // Owner-scoped: generating from somebody else's library is not allowed.
      const item = await one(
        'SELECT title, subject, status, extracted_text FROM content_items WHERE id = $1 AND owner_id = $2',
        [contentId, req.user.sub],
      );
      if (!item) throw notFound('Content not found.');
      if (item.status !== 'ready') {
        throw conflict(
          `That library item is "${item.status}", so there is no text to generate from yet.`,
          'content_id',
        );
      }
      sourceText = item.extracted_text;
      subject = subject || item.subject || item.title;
    }

    const text = assertGeneratableText(sourceText);
    const result = await generate({
      sourceText: text,
      count,
      difficultyMix: req.body?.difficulty_mix,
      subject,
    });

    res.json({
      questions: result.questions,
      provider: result.provider,
      model: result.model,
      attempts: result.attempts,
    });
  },
);
