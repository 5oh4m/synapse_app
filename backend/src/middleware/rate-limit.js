// Rate limits from docs/API.md:
//   /auth/login and /auth/register  10 / 15 min per IP
//   /generate                       20 / hour per user
// Both answer 429 with Retry-After. The previous server had none at all.
import { rateLimit, ipKeyGenerator } from 'express-rate-limit';
// Imported for the limits, and so config.js (which loads .env) is guaranteed to
// have evaluated before these limiters read their thresholds.
import { config } from '../config.js';
import { ApiError } from '../errors.js';

function limitHandler(req, res, next, options) {
  const resetMs = req.rateLimit?.resetTime
    ? new Date(req.rateLimit.resetTime).getTime() - Date.now()
    : options.windowMs;
  const retryAfter = Math.max(1, Math.ceil(resetMs / 1000));
  res.setHeader('Retry-After', String(retryAfter));
  next(new ApiError('RATE_LIMITED', options.message || 'Too many requests. Try again shortly.'));
}

const base = {
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  handler: limitHandler,
};

/** Per-IP. Credential stuffing and signup spam. */
export const authLimiter = rateLimit({
  ...base,
  windowMs: 15 * 60 * 1000,
  limit: config.rateLimits.auth,
  keyGenerator: (req) => ipKeyGenerator(req.ip),
  message: 'Too many sign-in attempts from this address. Try again in a few minutes.',
});

/** Per-user: generation costs money upstream, so the token subject is the key. */
export const generateLimiter = rateLimit({
  ...base,
  windowMs: 60 * 60 * 1000,
  limit: config.rateLimits.generate,
  keyGenerator: (req) => req.user?.sub || ipKeyGenerator(req.ip),
  message: 'Generation limit reached (20 per hour). Try again later.',
});

/** Coarse backstop for everything else, so one client cannot flood the pool. */
export const globalLimiter = rateLimit({
  ...base,
  windowMs: 60 * 1000,
  limit: config.rateLimits.global,
  keyGenerator: (req) => req.user?.sub || ipKeyGenerator(req.ip),
  message: 'Too many requests. Slow down.',
});
