// Boot-time configuration. Fails fast with a readable message when a required
// value is missing, rather than 500ing on the first request.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

const here = path.dirname(fileURLToPath(import.meta.url));
export const BACKEND_ROOT = path.resolve(here, '..');

// .env.test wins when running tests so `npm test` can never touch the dev db.
const envFile = process.env.NODE_ENV === 'test' ? '.env.test' : '.env';
dotenv.config({ path: path.join(BACKEND_ROOT, envFile), quiet: true });
// Fall back to .env for anything .env.test did not set (JWT_SECRET, AI keys).
if (process.env.NODE_ENV === 'test') {
  dotenv.config({ path: path.join(BACKEND_ROOT, '.env'), quiet: true });
}

const missing = [];
function required(name, fallback) {
  const v = process.env[name] || fallback;
  if (!v) missing.push(name);
  return v;
}

const int = (name, def) => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return def;
  const n = Number(raw);
  return Number.isFinite(n) ? n : def;
};

export const config = {
  env: process.env.NODE_ENV || 'development',
  port: int('PORT', 8787),
  databaseUrl: required('DATABASE_URL'),
  jwtSecret: required('JWT_SECRET'),
  accessTtlSeconds: int('ACCESS_TTL_SECONDS', 15 * 60),
  refreshTtlDays: int('REFRESH_TTL_DAYS', 30),
  // Cost 12 per docs/API.md. Overridable only so the test suite (which
  // registers dozens of users) does not spend a minute in key stretching.
  bcryptCost: int('BCRYPT_COST', 12),
  corsOrigins: String(process.env.CORS_ORIGINS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  bodyLimitBytes: int('BODY_LIMIT_BYTES', 1024 * 1024),
  uploadLimitBytes: int('UPLOAD_LIMIT_BYTES', 20 * 1024 * 1024),
  rateLimits: {
    // docs/API.md: sign-in 10 per 15 min per (IP, email), with a much higher
    // per-IP ceiling because a whole class shares one school address;
    // generation 20 per hour per user; everything else per user when signed in.
    auth: int('RATE_LIMIT_AUTH', 10),
    authPerIp: int('RATE_LIMIT_AUTH_IP', 300),
    generate: int('RATE_LIMIT_GENERATE', 20),
    global: int('RATE_LIMIT_GLOBAL', 600),
  },
  // Hops of reverse proxy in front of the server. 0 (the default) means
  // X-Forwarded-For is ignored, so a client cannot choose its own IP.
  trustProxyHops: int('TRUST_PROXY_HOPS', 0),
  // How long a participant may have no open socket before the host sees them
  // as disconnected. Covers a page reload or a quick wifi blip.
  presenceGraceMs: int('PRESENCE_GRACE_MS', 5_000),
  wsMaxPayloadBytes: int('WS_MAX_PAYLOAD_BYTES', 64 * 1024),
  ai: {
    provider: (process.env.AI_PROVIDER || process.env.AI || 'mock').toLowerCase(),
    apiKey: process.env.ANTHROPIC_API_KEY || '',
    // Real model id. `claude-sonnet-5` does not exist and 400s.
    model: process.env.ANTHROPIC_MODEL || 'claude-sonnet-4-20250514',
    maxRetries: int('AI_MAX_RETRIES', 3),
  },
  answerGraceMs: int('ANSWER_GRACE_MS', 750),
  autoRevealTickMs: int('AUTO_REVEAL_TICK_MS', 500),
  autoAdvanceSeconds: int('AUTO_ADVANCE_SECONDS', 5),
  answerCoalesceMs: int('ANSWER_COALESCE_MS', 250),
  heartbeatMs: int('HEARTBEAT_MS', 30_000),
  logLevel: process.env.LOG_LEVEL || (process.env.NODE_ENV === 'test' ? 'error' : 'info'),
};

export function assertConfig() {
  if (missing.length === 0) return;
  const lines = [
    '',
    'quizzle backend cannot start: missing required configuration.',
    '',
    ...missing.map((m) => `  - ${m} is not set`),
    '',
    `Create ${path.join(BACKEND_ROOT, '.env')} from .env.example:`,
    '',
    '  cp backend/.env.example backend/.env',
    '  # then set JWT_SECRET to 32+ random bytes:',
    '  node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'base64url\'))"',
    '',
  ];
  console.error(lines.join('\n'));
  process.exit(1);
}

export const isProd = config.env === 'production';
