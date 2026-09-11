// Question generation.
//
// Defects fixed:
//  - Hallucinated model id. The default was `claude-sonnet-5`, which does not
//    exist and 400s. Default is now claude-sonnet-4-20250514, env-overridable.
//  - Brittle parsing. The old code did text.indexOf('{') / lastIndexOf('}'),
//    which mis-slices the moment the model writes prose containing a brace
//    ("use {x} as..."), or emits two JSON blocks. extractJsonObjects below is a
//    real scanner: it tracks string literals and backslash escapes and returns
//    balanced candidates, largest first.
//  - A parse failure took the process down. Now: retry up to 3 times, then 502
//    with the reason. Nothing here throws past the route.
import crypto from 'node:crypto';
import { config } from '../config.js';
import { log } from '../log.js';
import { upstream, validation } from '../errors.js';
import { validateQuestion, defaultTimeFor } from '../util/validate.js';

/**
 * Scans `text` for balanced top-level {...} runs, respecting double-quoted
 * string literals and backslash escapes so braces inside strings or prose do
 * not confuse the bounds. Returns candidates sorted longest-first.
 */
export function extractJsonObjects(text) {
  const src = String(text ?? '');
  const found = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escaped = false;

  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];

    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === '{') {
      if (depth === 0) start = i;
      depth += 1;
      continue;
    }
    if (ch === '}') {
      if (depth === 0) continue; // stray closer in prose
      depth -= 1;
      if (depth === 0 && start >= 0) {
        found.push(src.slice(start, i + 1));
        start = -1;
      }
    }
  }
  return found.sort((a, b) => b.length - a.length);
}

/** First balanced candidate that both parses and satisfies `accept`. */
export function parseJsonFromText(text, accept = () => true) {
  // A response that is already pure JSON is the common case.
  const direct = String(text ?? '').trim();
  if (direct.startsWith('{') || direct.startsWith('[')) {
    try {
      const v = JSON.parse(direct);
      if (accept(v)) return v;
    } catch {
      /* fall through to scanning */
    }
  }
  for (const candidate of extractJsonObjects(text)) {
    try {
      const v = JSON.parse(candidate);
      if (accept(v)) return v;
    } catch {
      /* try the next candidate */
    }
  }
  return null;
}

const hasQuestions = (v) => v && typeof v === 'object' && Array.isArray(v.questions);

// --------------------------------------------------------- difficulty mix ----

export function resolveDifficulties(mix, count) {
  const weights = Object.entries(mix || {}).filter(([d]) => ['easy', 'medium', 'hard'].includes(d));
  const total = weights.reduce((a, [, w]) => a + Math.max(0, Number(w) || 0), 0);
  if (total <= 0) return Array.from({ length: count }, () => 'medium');
  const out = [];
  for (const [d, w] of weights) {
    const n = Math.round((Math.max(0, Number(w) || 0) / total) * count);
    for (let i = 0; i < n; i += 1) out.push(d);
  }
  while (out.length < count) out.push('medium');
  return out.slice(0, count);
}

// -------------------------------------------------------------- mock mode ----

function shuffle(a) {
  for (let i = a.length - 1; i > 0; i -= 1) {
    const j = crypto.randomInt(i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const STOP = new Set([
  'the', 'and', 'for', 'are', 'with', 'from', 'that', 'this', 'which', 'their',
  'they', 'have', 'been', 'were', 'into', 'these', 'such', 'also', 'when',
  'what', 'where', 'because', 'while', 'about', 'there', 'other', 'than',
]);

/** Offline cloze generator. Deterministic enough to demo without a key. */
export function mockGenerate({ sourceText, difficulties, subject }) {
  const sentences = String(sourceText || '')
    .replace(/\[Slide \d+\]/g, ' ')
    .replace(/\s+/g, ' ')
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 24 && s.split(' ').length <= 40);

  const vocabulary = [
    ...new Set(
      sentences
        .join(' ')
        .split(/\s+/)
        .map((w) => w.replace(/[^A-Za-z0-9-]/g, ''))
        .filter((w) => w.length >= 4 && !STOP.has(w.toLowerCase())),
    ),
  ];

  const out = [];
  for (let i = 0; i < difficulties.length; i += 1) {
    const sentence = sentences[i % Math.max(1, sentences.length)] || `A key idea in ${subject || 'this material'}`;
    const words = sentence
      .split(/\s+/)
      .map((w) => w.replace(/[^A-Za-z0-9-]/g, ''))
      .filter((w) => w.length >= 4 && !STOP.has(w.toLowerCase()));
    const answer = [...words].sort((a, b) => b.length - a.length)[0] || subject || 'concept';
    const distractors = shuffle(
      vocabulary.filter((w) => w.toLowerCase() !== answer.toLowerCase()),
    ).slice(0, 3);
    while (distractors.length < 3) {
      distractors.push(['none of these', 'all of these', 'not stated in the material'][distractors.length]);
    }
    const options = shuffle([answer, ...distractors]);
    const difficulty = difficulties[i];
    out.push({
      question_text: `Fill in the blank: "${sentence.replace(answer, '_____').slice(0, 200)}"`,
      options,
      correct_index: Math.max(0, options.indexOf(answer)),
      explanation: `The material states: "${sentence.slice(0, 160)}"`,
      difficulty,
      source_reference: `Page ${1 + Math.floor(i / 3)}`,
      time_limit_seconds: defaultTimeFor(difficulty),
    });
  }
  return out;
}

// ----------------------------------------------------------- anthropic -------

const SYSTEM_PROMPT =
  'You write multiple-choice quiz questions from supplied teaching material. ' +
  'You reply with a single JSON object and no prose, no markdown fence, no commentary.';

function buildPrompt({ sourceText, count, difficulties, subject }) {
  const mix = difficulties.reduce((m, d) => ({ ...m, [d]: (m[d] || 0) + 1 }), {});
  return [
    `Write exactly ${count} multiple-choice questions for the subject "${subject || 'this material'}".`,
    `Difficulty counts: ${JSON.stringify(mix)}.`,
    'Every question must be answerable from the material below and nothing else.',
    '',
    'Material:',
    '"""',
    String(sourceText).slice(0, 24_000),
    '"""',
    '',
    'Reply with exactly this JSON shape and nothing else:',
    '{"questions":[{"question_text":string,"options":[string,string,string,string],' +
      '"correct_index":0|1|2|3,"explanation":string,"difficulty":"easy"|"medium"|"hard",' +
      '"source_reference":string}]}',
    '',
    'Rules: exactly 4 options, all non-empty and distinct; correct_index points at the right one;',
    'explanation cites the material; source_reference names the page or slide.',
  ].join('\n');
}

async function callAnthropic({ sourceText, count, difficulties, subject, signal }) {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    signal,
    headers: {
      'x-api-key': config.ai.apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: config.ai.model,
      max_tokens: 8192,
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: buildPrompt({ sourceText, count, difficulties, subject }) }],
    }),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    const err = new Error(`Anthropic returned ${res.status}${detail ? `: ${detail.slice(0, 300)}` : ''}`);
    // 4xx other than 429 will not fix themselves on retry.
    err.retryable = res.status === 429 || res.status >= 500;
    throw err;
  }

  const data = await res.json();
  return (data.content || [])
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('');
}

// ---------------------------------------------------------------- public -----

/**
 * @returns {{questions: object[], provider: string, model: string|null, attempts: number}}
 * Throws only ApiError (VALIDATION / UPSTREAM).
 */
export async function generate({ sourceText, count, difficultyMix, subject }) {
  const difficulties = resolveDifficulties(difficultyMix, count);
  const useAnthropic = config.ai.provider === 'anthropic' && Boolean(config.ai.apiKey);

  if (!useAnthropic) {
    if (config.ai.provider === 'anthropic' && !config.ai.apiKey) {
      log.warn('AI_PROVIDER=anthropic but ANTHROPIC_API_KEY is empty; using the mock generator');
    }
    const questions = mockGenerate({ sourceText, difficulties, subject }).map((q, i) =>
      validateQuestion(q, { label: `question ${i + 1}` }),
    );
    return { questions, provider: 'mock', model: null, attempts: 1 };
  }

  const problems = [];
  for (let attempt = 1; attempt <= config.ai.maxRetries; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 90_000);
    try {
      const text = await callAnthropic({
        sourceText,
        count,
        difficulties,
        subject,
        signal: controller.signal,
      });
      const parsed = parseJsonFromText(text, hasQuestions);
      if (!parsed) throw Object.assign(new Error('the reply contained no parsable JSON object with a "questions" array'), { retryable: true });

      const questions = parsed.questions.map((q, i) =>
        validateQuestion(
          { ...q, time_limit_seconds: q.time_limit_seconds ?? defaultTimeFor(q.difficulty) },
          { label: `question ${i + 1}` },
        ),
      );
      if (questions.length === 0) {
        throw Object.assign(new Error('the reply contained zero questions'), { retryable: true });
      }
      return { questions, provider: 'anthropic', model: config.ai.model, attempts: attempt };
    } catch (err) {
      problems.push(`attempt ${attempt}: ${err.message}`);
      log.warn('generation attempt failed', { attempt, message: err.message });
      const retryable = err.retryable !== false;
      if (!retryable || attempt === config.ai.maxRetries) break;
      await new Promise((r) => setTimeout(r, 400 * attempt));
    } finally {
      clearTimeout(timeout);
    }
  }

  // Never crash, never silently substitute: say what happened.
  throw upstream(
    `Question generation failed after ${problems.length} attempt(s) with model ${config.ai.model}. ${problems.join(' | ')}`,
  );
}

export function assertGeneratableText(text) {
  const t = String(text || '').trim();
  if (t.length < 120) {
    throw validation(
      'There is not enough source text to write questions from (at least 120 characters).',
      'source_text',
    );
  }
  return t;
}
