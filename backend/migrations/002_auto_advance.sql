-- Add revealed_at timestamp to quiz_sessions for server-driven auto-advance.
ALTER TABLE quiz_sessions ADD COLUMN IF NOT EXISTS revealed_at timestamptz;
CREATE INDEX IF NOT EXISTS quiz_sessions_auto_advance_idx ON quiz_sessions (revealed_at)
  WHERE status = 'active' AND phase = 'revealing';

