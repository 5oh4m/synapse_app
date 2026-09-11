// Field-level validators. Every failure throws an ApiError carrying the field
// name so the client can attach the message to the right input.
import { validation, badRequest } from '../errors.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export const isUuid = (v) => typeof v === 'string' && UUID_RE.test(v);

export function assertUuid(value, field) {
  if (!isUuid(value)) throw badRequest(`${field} must be a UUID.`, field);
  return value;
}

export function str(body, field, { required = false, max = 500, min = 0, trim = true } = {}) {
  let v = body?.[field];
  if (v === undefined || v === null) {
    if (required) throw validation(`${field} is required.`, field);
    return undefined;
  }
  if (typeof v !== 'string') throw validation(`${field} must be a string.`, field);
  if (trim) v = v.trim();
  if (v.length < min) throw validation(`${field} must be at least ${min} characters.`, field);
  if (v.length > max) throw validation(`${field} must be at most ${max} characters.`, field);
  if (required && v.length === 0) throw validation(`${field} is required.`, field);
  return v;
}

export function int(body, field, { required = false, min, max, def } = {}) {
  const raw = body?.[field];
  if (raw === undefined || raw === null || raw === '') {
    if (required) throw validation(`${field} is required.`, field);
    return def;
  }
  const n = typeof raw === 'number' ? raw : Number(raw);
  if (!Number.isInteger(n)) throw validation(`${field} must be a whole number.`, field);
  if (min !== undefined && n < min) throw validation(`${field} must be at least ${min}.`, field);
  if (max !== undefined && n > max) throw validation(`${field} must be at most ${max}.`, field);
  return n;
}

export function oneOf(body, field, allowed, { required = false, def } = {}) {
  const v = body?.[field];
  if (v === undefined || v === null || v === '') {
    if (required) throw validation(`${field} is required.`, field);
    return def;
  }
  if (!allowed.includes(v)) {
    throw validation(`${field} must be one of: ${allowed.join(', ')}.`, field);
  }
  return v;
}

export function email(body, field = 'email') {
  const v = str(body, field, { required: true, max: 254 });
  if (!EMAIL_RE.test(v)) throw validation('Enter a valid email address.', field);
  return v.toLowerCase();
}

export function password(body, field = 'password') {
  const v = body?.[field];
  if (typeof v !== 'string' || v.length < 8) {
    throw validation('Password must be at least 8 characters.', field);
  }
  if (v.length > 200) throw validation('Password must be at most 200 characters.', field);
  return v;
}

/**
 * docs/API.md: identity never comes from the body. Any request that supplies
 * one of these is rejected outright rather than silently ignored, so a client
 * bug surfaces immediately instead of looking like it worked.
 */
const FORBIDDEN_BODY_FIELDS = ['owner_id', 'ownerId', 'student_id', 'studentId', 'host_id', 'hostId', 'user_id', 'userId'];

export function rejectIdentityFields(body) {
  if (!body || typeof body !== 'object') return;
  for (const f of FORBIDDEN_BODY_FIELDS) {
    if (f in body) {
      throw badRequest(
        `${f} is not accepted in the request body; identity comes from the access token.`,
        f,
      );
    }
  }
}

export const QUESTION_RULES = {
  minOptions: 4,
  minTime: 5,
  maxTime: 120,
};

/**
 * Validates one question payload against the shape in docs/API.md.
 * `label` prefixes messages when validating a batch.
 */
export function validateQuestion(raw, { label = 'question' } = {}) {
  if (!raw || typeof raw !== 'object') throw validation(`${label} must be an object.`, 'questions');

  const question_text = String(raw.question_text ?? raw.question ?? '').trim();
  if (!question_text) throw validation(`${label}: question_text is required.`, 'question_text');
  if (question_text.length > 2000) {
    throw validation(`${label}: question_text is too long (max 2000).`, 'question_text');
  }

  const options = Array.isArray(raw.options) ? raw.options.map((o) => String(o ?? '').trim()) : null;
  if (!options || options.length !== 4) {
    throw validation(`${label}: exactly 4 options are required.`, 'options');
  }
  if (options.some((o) => o.length === 0)) {
    throw validation(`${label}: options cannot be empty.`, 'options');
  }
  if (options.some((o) => o.length > 500)) {
    throw validation(`${label}: an option is too long (max 500).`, 'options');
  }
  if (new Set(options.map((o) => o.toLowerCase())).size !== 4) {
    throw validation(`${label}: the 4 options must be distinct.`, 'options');
  }

  const correct_index = raw.correct_index;
  if (!Number.isInteger(correct_index) || correct_index < 0 || correct_index > 3) {
    throw validation(`${label}: correct_index must be 0, 1, 2 or 3.`, 'correct_index');
  }

  const difficulty = ['easy', 'medium', 'hard'].includes(raw.difficulty) ? raw.difficulty : 'medium';

  let time_limit_seconds = raw.time_limit_seconds;
  if (time_limit_seconds === undefined || time_limit_seconds === null || time_limit_seconds === '') {
    time_limit_seconds = defaultTimeFor(difficulty);
  }
  time_limit_seconds = Number(time_limit_seconds);
  if (
    !Number.isInteger(time_limit_seconds) ||
    time_limit_seconds < QUESTION_RULES.minTime ||
    time_limit_seconds > QUESTION_RULES.maxTime
  ) {
    throw validation(
      `${label}: time_limit_seconds must be between ${QUESTION_RULES.minTime} and ${QUESTION_RULES.maxTime}.`,
      'time_limit_seconds',
    );
  }

  return {
    question_text,
    options,
    correct_index,
    explanation: String(raw.explanation ?? '').trim().slice(0, 2000),
    difficulty,
    source_reference: String(raw.source_reference ?? '').trim().slice(0, 200),
    time_limit_seconds,
  };
}

export const defaultTimeFor = (d) => (d === 'easy' ? 15 : d === 'hard' ? 30 : 20);
