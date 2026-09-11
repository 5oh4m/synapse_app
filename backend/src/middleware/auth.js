// requireAuth / requireRole. `req.user` is the ONLY source of caller identity
// anywhere in the app — no route reads owner_id/student_id/host_id from a body.
import { verifyAccessToken } from '../services/auth.service.js';
import { unauthorized, forbidden } from '../errors.js';

function bearer(req) {
  const header = req.get('authorization') || '';
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  return m ? m[1].trim() : null;
}

export function requireAuth(req, _res, next) {
  const token = bearer(req);
  if (!token) return next(unauthorized('Sign in to continue.'));
  try {
    const claims = verifyAccessToken(token);
    req.user = { sub: claims.sub, role: claims.role, email: claims.email, name: claims.name };
    return next();
  } catch (err) {
    const expired = err && err.name === 'TokenExpiredError';
    return next(unauthorized(expired ? 'Your session expired. Sign in again.' : 'Invalid access token.'));
  }
}

export const requireRole = (...roles) => (req, _res, next) => {
  if (!req.user) return next(unauthorized());
  if (!roles.includes(req.user.role)) {
    return next(forbidden(`This action is for ${roles.join(' or ')} accounts.`));
  }
  return next();
};

/** For the WS upgrade, which has no Express req. */
export function userFromToken(token) {
  try {
    const claims = verifyAccessToken(token);
    return { sub: claims.sub, role: claims.role, email: claims.email, name: claims.name };
  } catch {
    return null;
  }
}
