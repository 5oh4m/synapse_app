// Middleware wiring. Everything security-relevant is here or one hop away.
import crypto from 'node:crypto';
import express from 'express';
import cors from 'cors';
import { config, isProd } from './config.js';
import { log } from './log.js';
import { ApiError, notFound } from './errors.js';
import { globalLimiter } from './middleware/rate-limit.js';
import { authRoutes } from './routes/auth.js';
import { contentRoutes, multerErrorHandler } from './routes/content.js';
import { quizRoutes } from './routes/quizzes.js';
import { questionRoutes } from './routes/questions.js';
import { generateRoutes } from './routes/generate.js';
import { sessionRoutes } from './routes/sessions.js';
import { leaderboardRoutes } from './routes/leaderboard.js';
import { analyticsRoutes } from './routes/analytics.js';
import { hubStats } from './realtime/hub.js';
import { pool } from './db/pool.js';

/**
 * Explicit allowlist from CORS_ORIGINS. The previous server sent
 * `access-control-allow-origin: *` on every response, which — combined with
 * bearer tokens — let any page on the internet drive the API as the signed-in
 * user. No wildcard here, ever.
 */
function corsMiddleware() {
  const allowed = new Set(config.corsOrigins);
  return cors({
    origin(origin, cb) {
      // No Origin header: curl, a native app, server-to-server. Not a browser
      // cross-origin request, so there is nothing for CORS to protect.
      if (!origin) return cb(null, true);
      if (allowed.has(origin)) return cb(null, true);
      log.warn('cors rejected', { origin });
      return cb(new ApiError('FORBIDDEN', `Origin ${origin} is not allowed.`));
    },
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
    exposedHeaders: ['Retry-After', 'X-Request-Id'],
    maxAge: 600,
  });
}

export function createApp() {
  const app = express();

  app.set('trust proxy', Number(process.env.TRUST_PROXY_HOPS || 1));
  app.disable('x-powered-by');
  app.set('etag', false);

  // Request id on every response; the only thing a 500 body reveals.
  app.use((req, res, next) => {
    req.id = req.get('x-request-id') || crypto.randomUUID();
    res.setHeader('X-Request-Id', req.id);
    next();
  });

  app.use(corsMiddleware());

  // 1 MB body limit, enforced while reading. Past it Express raises
  // entity.too.large and the error handler destroys the connection.
  app.use(
    express.json({
      limit: config.bodyLimitBytes,
      strict: true,
      type: ['application/json', 'application/*+json'],
    }),
  );
  app.use(express.urlencoded({ extended: false, limit: config.bodyLimitBytes }));

  if (config.logLevel === 'debug' || config.logLevel === 'info') {
    app.use((req, res, next) => {
      const started = process.hrtime.bigint();
      res.on('finish', () => {
        const ms = Number(process.hrtime.bigint() - started) / 1e6;
        log.info('request', {
          rid: req.id,
          method: req.method,
          path: req.originalUrl.split('?')[0],
          status: res.statusCode,
          ms: Math.round(ms),
          uid: req.user?.sub,
        });
      });
      next();
    });
  }

  app.get('/health', async (_req, res) => {
    let db = 'down';
    try {
      await pool.query('SELECT 1');
      db = 'up';
    } catch {
      db = 'down';
    }
    res
      .status(db === 'up' ? 200 : 503)
      .json({ ok: db === 'up', db, ai_provider: config.ai.provider, ws: hubStats() });
  });

  const api = express.Router();
  api.use(globalLimiter);
  api.use('/auth', authRoutes);
  api.use('/content', contentRoutes);
  api.use('/quizzes', quizRoutes);
  api.use('/questions', questionRoutes);
  api.use('/generate', generateRoutes);
  api.use('/sessions', sessionRoutes);
  api.use('/leaderboard', leaderboardRoutes);
  api.use('/analytics', analyticsRoutes);
  app.use('/api', api);

  // Unrouted paths get the same error envelope as everything else.
  app.use((req, _res, next) => next(notFound(`No route for ${req.method} ${req.path}.`)));

  app.use(multerErrorHandler);
  app.use(errorHandler);

  return app;
}

export function errorHandler(err, req, res, _next) {
  if (res.headersSent) {
    res.destroy();
    return;
  }

  if (err instanceof ApiError) {
    // Every field-level rejection lands here; nothing is logged at error level
    // for an ordinary 4xx.
    if (err.status >= 500) log.error('api error', { rid: req.id, code: err.code, message: err.message });
    return res.status(err.status).json(err.toJSON());
  }

  // Oversized body: reject and drop the connection, per docs/API.md.
  if (err?.type === 'entity.too.large') {
    res.status(413).json({
      error: {
        code: 'VALIDATION',
        message: `Request body exceeds the ${Math.round(config.bodyLimitBytes / 1024)} KB limit.`,
      },
    });
    return res.destroy();
  }
  if (err?.type === 'entity.parse.failed') {
    return res.status(400).json({
      error: { code: 'VALIDATION', message: 'Request body is not valid JSON.' },
    });
  }

  // Anything unhandled: log the full detail server-side, return an id.
  log.error('unhandled error', {
    rid: req.id,
    message: err?.message,
    code: err?.code,
    stack: isProd ? undefined : err?.stack,
  });
  return res.status(500).json({
    error: {
      code: 'INTERNAL',
      message: `Something went wrong. Quote request id ${req.id} if you report this.`,
    },
  });
}
