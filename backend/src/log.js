// Minimal structured logger. Never logs passwords, hashes or tokens — call
// sites pass explicit fields, never whole request bodies.
import { config } from './config.js';

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };
const threshold = LEVELS[config.logLevel] ?? LEVELS.info;

const REDACT = new Set([
  'password',
  'password_hash',
  'passwordHash',
  'token',
  'accessToken',
  'refreshToken',
  'refresh_token',
  'authorization',
  'apiKey',
  'ANTHROPIC_API_KEY',
  'JWT_SECRET',
]);

function scrub(value, depth = 0) {
  if (depth > 4 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((v) => scrub(v, depth + 1));
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = REDACT.has(k) ? '[redacted]' : scrub(v, depth + 1);
  }
  return out;
}

function emit(level, message, fields) {
  if (LEVELS[level] > threshold) return;
  const line = { t: new Date().toISOString(), level, message, ...scrub(fields || {}) };
  const stream = level === 'error' ? console.error : console.log;
  stream(JSON.stringify(line));
}

export const log = {
  error: (m, f) => emit('error', m, f),
  warn: (m, f) => emit('warn', m, f),
  info: (m, f) => emit('info', m, f),
  debug: (m, f) => emit('debug', m, f),
  /** Human-friendly banner for boot messages, not JSON. */
  banner: (m) => {
    if (config.logLevel !== 'silent') console.log(m);
  },
};
