import { Router } from 'express';
import * as auth from '../services/auth.service.js';
import { requireAuth } from '../middleware/auth.js';
import { authLimiter, authIpLimiter } from '../middleware/rate-limit.js';
import { email, password, str, oneOf, rejectIdentityFields } from '../util/validate.js';

export const authRoutes = Router();

authRoutes.post('/register', authIpLimiter, authLimiter, async (req, res) => {
  rejectIdentityFields(req.body);
  const payload = {
    name: str(req.body, 'name', { required: true, max: 80 }),
    email: email(req.body),
    password: password(req.body),
    role: oneOf(req.body, 'role', ['educator', 'student'], { required: true }),
  };
  const out = await auth.register(payload);
  res.status(201).json(out);
});

authRoutes.post('/login', authIpLimiter, authLimiter, async (req, res) => {
  const out = await auth.login({
    email: email(req.body),
    // Not `password()`: an existing short password must still be able to sign
    // in, and the length rule would leak that the rules changed.
    password: String(req.body?.password ?? ''),
  });
  res.json(out);
});

authRoutes.post('/refresh', async (req, res) => {
  const out = await auth.refresh(req.body?.refreshToken ?? req.body?.refresh_token);
  res.json(out);
});

authRoutes.post('/logout', requireAuth, async (req, res) => {
  await auth.revokeRefreshToken(req.body?.refreshToken ?? req.body?.refresh_token, req.user.sub);
  res.status(204).end();
});

authRoutes.get('/me', requireAuth, async (req, res) => {
  res.json({ user: await auth.getUser(req.user.sub) });
});

authRoutes.patch('/me', requireAuth, async (req, res) => {
  rejectIdentityFields(req.body);
  const name = str(req.body, 'name', { max: 80 });
  res.json({ user: await auth.updateProfile(req.user.sub, { name }) });
});
