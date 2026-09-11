-- quizzle initial schema. Mirrors docs/API.md "Postgres schema".
-- UUID v4 keys via pgcrypto; case-insensitive emails via citext.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text        NOT NULL,
  email         citext      NOT NULL UNIQUE,
  password_hash text        NOT NULL,
  role          text        NOT NULL CHECK (role IN ('educator', 'student')),
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Opaque 256-bit refresh tokens, SHA-256 hashed at rest. Rotated on use.
CREATE TABLE refresh_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash text        NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id);

CREATE TABLE content_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id       uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  title          text        NOT NULL,
  subject        text,
  source_type    text        NOT NULL CHECK (source_type IN ('pdf', 'pptx', 'image', 'text')),
  status         text        NOT NULL CHECK (status IN ('processing', 'ready', 'needs_text', 'failed')),
  extracted_text text        NOT NULL DEFAULT '',
  page_count     int         NOT NULL DEFAULT 0,
  file_name      text,
  error          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX content_items_owner_idx ON content_items (owner_id, created_at DESC);

CREATE TABLE quizzes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id        uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  title           text        NOT NULL,
  subject         text,
  description     text        NOT NULL DEFAULT '',
  content_id      uuid        REFERENCES content_items (id) ON DELETE SET NULL,
  status          text        NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published')),
  base_points     int         NOT NULL DEFAULT 500 CHECK (base_points >= 0),
  speed_bonus_max int         NOT NULL DEFAULT 500 CHECK (speed_bonus_max >= 0),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX quizzes_owner_idx ON quizzes (owner_id, created_at DESC);
CREATE INDEX quizzes_status_idx ON quizzes (status) WHERE status = 'published';

CREATE TABLE questions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quiz_id            uuid  NOT NULL REFERENCES quizzes (id) ON DELETE CASCADE,
  question_text      text  NOT NULL,
  options            jsonb NOT NULL,
  correct_index      int   NOT NULL CHECK (correct_index BETWEEN 0 AND 3),
  explanation        text  NOT NULL DEFAULT '',
  difficulty         text  NOT NULL DEFAULT 'medium' CHECK (difficulty IN ('easy', 'medium', 'hard')),
  source_reference   text  NOT NULL DEFAULT '',
  order_index        int   NOT NULL,
  time_limit_seconds int   NOT NULL DEFAULT 20 CHECK (time_limit_seconds BETWEEN 5 AND 120),
  created_at         timestamptz NOT NULL DEFAULT now(),
  -- Deferrable so reorder can swap indexes inside one transaction, but a
  -- committed duplicate order_index is impossible. This is the data-layer fix
  -- for the "Regenerate duplicated a question" bug.
  CONSTRAINT questions_quiz_order_key UNIQUE (quiz_id, order_index)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX questions_quiz_idx ON questions (quiz_id, order_index);

CREATE TABLE quiz_sessions (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quiz_id                uuid        NOT NULL REFERENCES quizzes (id) ON DELETE CASCADE,
  host_id                uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  quiz_title             text        NOT NULL,
  join_code              text        NOT NULL UNIQUE,
  status                 text        NOT NULL DEFAULT 'lobby' CHECK (status IN ('lobby', 'active', 'ended')),
  current_question_index int         NOT NULL DEFAULT -1,
  total_questions        int         NOT NULL DEFAULT 0,
  phase                  text        NOT NULL DEFAULT 'asking' CHECK (phase IN ('asking', 'revealing')),
  question_started_at    timestamptz,
  question_ends_at       timestamptz,
  started_at             timestamptz,
  ended_at               timestamptz,
  allow_late_join        boolean     NOT NULL DEFAULT true,
  base_points            int         NOT NULL DEFAULT 500,
  speed_bonus_max        int         NOT NULL DEFAULT 500,
  created_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX quiz_sessions_host_idx ON quiz_sessions (host_id, created_at DESC);
CREATE INDEX quiz_sessions_quiz_idx ON quiz_sessions (quiz_id);
-- Drives the single server-side auto-reveal timer.
CREATE INDEX quiz_sessions_due_idx ON quiz_sessions (question_ends_at)
  WHERE status = 'active' AND phase = 'asking';

-- Frozen copy of the quiz at session-create time: editing the quiz mid-game
-- cannot change what is being played.
CREATE TABLE session_questions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id         uuid  NOT NULL REFERENCES quiz_sessions (id) ON DELETE CASCADE,
  source_question_id uuid,
  order_index        int   NOT NULL,
  question_text      text  NOT NULL,
  options            jsonb NOT NULL,
  correct_index      int   NOT NULL,
  explanation        text  NOT NULL DEFAULT '',
  difficulty         text  NOT NULL DEFAULT 'medium',
  source_reference   text  NOT NULL DEFAULT '',
  time_limit_seconds int   NOT NULL DEFAULT 20,
  UNIQUE (session_id, order_index)
);

CREATE TABLE session_participants (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id     uuid        NOT NULL REFERENCES quiz_sessions (id) ON DELETE CASCADE,
  user_id        uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  display_name   text        NOT NULL,
  total_score    int         NOT NULL DEFAULT 0,
  correct_count  int         NOT NULL DEFAULT 0,
  answered_count int         NOT NULL DEFAULT 0,
  streak         int         NOT NULL DEFAULT 0,
  connected      boolean     NOT NULL DEFAULT true,
  joined_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, user_id)
);
CREATE INDEX session_participants_user_idx ON session_participants (user_id);

CREATE TABLE responses (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id          uuid        NOT NULL REFERENCES quiz_sessions (id) ON DELETE CASCADE,
  participant_id      uuid        NOT NULL REFERENCES session_participants (id) ON DELETE CASCADE,
  session_question_id uuid        NOT NULL REFERENCES session_questions (id) ON DELETE CASCADE,
  question_index      int         NOT NULL,
  selected_index      int         NOT NULL,
  is_correct          boolean     NOT NULL,
  response_time_ms    int         NOT NULL,
  points_awarded      int         NOT NULL,
  answered_at         timestamptz NOT NULL DEFAULT now(),
  -- A double submit cannot rescore.
  UNIQUE (participant_id, question_index)
);
CREATE INDEX responses_session_idx ON responses (session_id, question_index);
CREATE INDEX responses_answered_idx ON responses (answered_at);
CREATE INDEX responses_sq_idx ON responses (session_question_id);
