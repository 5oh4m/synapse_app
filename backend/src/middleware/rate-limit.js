// Rate limits from docs/API.md:
//   /auth/login and /auth/register  10 / 15 min per (IP, email)
//                                   plus a per-IP ceiling (300 / 15 min)
//   /generate                       20 / hour per user
//   everything else                 600 / min per signed-in user, per IP otherwise
// All answer 429 with Retry-After.
//
// Keying matters in a classroom: thirty phones reach the server from one school
// address. A per-IP sign-in limit of 10 locked out the eleventh student, and a
// per-IP global bucket made every phone in the room share one allowance.
import { rateLimit, ipKeyGenerator } from 'express-rate-limit';
// Imported for the limits, and so config.js (which loads .env) is guaranteed to
// have evaluated before these limiters read their thresholds.
import { config } from '../config.js';
import { ApiError } from '../errors.js';
import { userFromToken } from './auth.js';

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

const emailOf = (req) => String(req.body?.email ?? '').trim().toLowerCase();

/**
 * The subject of a valid bearer token, if there is one. The global limiter runs
 * before `requireAuth`, so it cannot rely on `req.user`.
 */
function tokenSubject(req) {
  const m = /^Bearer\s+(.+)$/i.exec((req.get('authorization') || '').trim());
  return m ? (userFromToken(m[1].trim())?.sub ?? null) : null;
}

/**
 * Credential guessing against one account, from one address. Only failures
 * count, so a student who signs in on a second device is never locked out.
 */
export const authLimiter = rateLimit({
  ...base,
  windowMs: 15 * 60 * 1000,
  limit: config.rateLimits.auth,
  skipSuccessfulRequests: true,
  keyGenerator: (req) => `${ipKeyGenerator(req.ip)}|${emailOf(req)}`,
  message: 'Too many sign-in attempts for this account. Try again in a few minutes.',
});

/** Signup spam and spraying many accounts from one address. */
export const authIpLimiter = rateLimit({
  ...base,
  windowMs: 15 * 60 * 1000,
  limit: config.rateLimits.authPerIp,
  keyGenerator: (req) => ipKeyGenerator(req.ip),
  message: 'Too many sign-in attempts from this network. Try again in a few minutes.',
});

/** Per-user: generation costs money upstream, so the token subject is the key. */
export const generateLimiter = rateLimit({
  ...base,
  windowMs: 60 * 60 * 1000,
  limit: config.rateLimits.generate,
  keyGenerator: (req) => req.user?.sub || ipKeyGenerator(req.ip),
  message: 'Generation limit reached (20 per hour). Try again later.',
});

/** Coarse backstop, so one client cannot flood the pool. */
export const globalLimiter = rateLimit({
  ...base,
  windowMs: 60 * 1000,
  limit: config.rateLimits.global,
  keyGenerator: (req) => {
    const sub = tokenSubject(req);
    return sub ? `user:${sub}` : `ip:${ipKeyGenerator(req.ip)}`;
  },
  message: 'Too many requests. Slow down.',
});
