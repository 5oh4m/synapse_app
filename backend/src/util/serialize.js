// Row -> wire shape. Nothing here ever emits password_hash or a token hash.
//
// A few fields are emitted under two names. docs/API.md's Postgres schema uses
// `source_type` / `content_id` / `user_id`, while the Flutter models in
// lib/models/*.dart read `file_type` / `content_item_id` / `student_id`. Rather
// than break one of the two, the payloads carry both spellings; writes accept
// either. See docs/BACKEND.md "Field aliases".

const iso = (v) => (v instanceof Date ? v.toISOString() : v ?? null);

export const userJson = (u) => ({
  id: u.id,
  name: u.name,
  email: u.email,
  role: u.role,
  created_at: iso(u.created_at),
});

export const contentJson = (c) => ({
  id: c.id,
  owner_id: c.owner_id,
  title: c.title,
  subject: c.subject,
  source_type: c.source_type,
  file_type: c.source_type, // Flutter alias
  status: c.status,
  extracted_text: c.extracted_text ?? '',
  page_count: c.page_count ?? 0,
  file_name: c.file_name,
  file_url: c.file_name, // Flutter alias
  error: c.error,
  created_at: iso(c.created_at),
});

export const quizJson = (q) => ({
  id: q.id,
  owner_id: q.owner_id,
  title: q.title,
  subject: q.subject,
  description: q.description ?? '',
  content_id: q.content_id,
  content_item_id: q.content_id, // Flutter alias
  status: q.status,
  question_count: Number(q.question_count ?? 0),
  tags: [],
  scoring: {
    base_points: q.base_points,
    speed_bonus_max: q.speed_bonus_max,
  },
  created_at: iso(q.created_at),
  updated_at: iso(q.updated_at),
});

export const questionJson = (q) => ({
  id: q.id,
  quiz_id: q.quiz_id,
  question_text: q.question_text,
  options: q.options,
  correct_index: q.correct_index,
  explanation: q.explanation ?? '',
  difficulty: q.difficulty,
  source_reference: q.source_reference ?? '',
  order_index: q.order_index,
  time_limit_seconds: q.time_limit_seconds,
});

/** A snapshot row served as a question. `session_id` stands in for `quiz_id`. */
export const sessionQuestionJson = (q) => ({
  id: q.id,
  quiz_id: q.session_id,
  session_id: q.session_id,
  question_text: q.question_text,
  options: q.options,
  correct_index: q.correct_index,
  explanation: q.explanation ?? '',
  difficulty: q.difficulty,
  source_reference: q.source_reference ?? '',
  order_index: q.order_index,
  time_limit_seconds: q.time_limit_seconds,
});

/** docs/API.md: "Redacted question = correct_index: -1, explanation: ''". */
export const redactQuestion = (json) => ({ ...json, correct_index: -1, explanation: '' });

export const sessionJson = (s) => ({
  id: s.id,
  quiz_id: s.quiz_id,
  quiz_title: s.quiz_title,
  host_id: s.host_id,
  join_code: s.join_code,
  status: s.status,
  current_question_index: s.current_question_index,
  total_questions: s.total_questions,
  phase: s.phase,
  question_started_at: iso(s.question_started_at),
  question_ends_at: iso(s.question_ends_at),
  started_at: iso(s.started_at),
  ended_at: iso(s.ended_at),
  allow_late_join: s.allow_late_join,
  scoring: { base_points: s.base_points, speed_bonus_max: s.speed_bonus_max },
  created_at: iso(s.created_at),
});

export const participantJson = (p) => ({
  id: p.id,
  session_id: p.session_id,
  user_id: p.user_id,
  student_id: p.user_id, // Flutter alias
  display_name: p.display_name,
  total_score: p.total_score,
  correct_count: p.correct_count,
  answered_count: p.answered_count,
  streak: p.streak,
  connected: p.connected,
  last_answered_index: p.last_answered_index ?? -1,
  joined_at: iso(p.joined_at),
});

export const responseJson = (r) => ({
  id: r.id,
  session_id: r.session_id,
  participant_id: r.participant_id,
  student_id: r.user_id ?? null, // Flutter alias, when joined in
  session_question_id: r.session_question_id,
  question_id: r.session_question_id, // Flutter alias
  question_index: r.question_index,
  selected_index: r.selected_index,
  is_correct: r.is_correct,
  response_time_ms: r.response_time_ms,
  points_awarded: r.points_awarded,
  answered_at: iso(r.answered_at),
});
