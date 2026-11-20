# quizzle API contract v2

Source of truth for the backend rewrite and the Flutter client. If you need to deviate,
update this file in the same change so the other side stays in sync.

Base: `http://localhost:8787/api` · All bodies JSON · All timestamps ISO-8601 UTC.

## Security rules that drive the whole design

These exist because the previous implementation was exploitable. They are requirements, not
suggestions.

1. **Identity always comes from the JWT, never the body.** No endpoint accepts `owner_id`,
   `student_id`, or `host_id` from the client. Reject any request that supplies them.
2. **Server owns all timing.** Response time is `now - session.question_started_at`, computed
   server-side. `response_time_ms` from a client is ignored entirely.
3. **Ownership is checked on every mutation.** Quizzes/content: caller must be `owner_id`.
   Session control: caller must be `host_id`. Wrong owner → `404` (not `403`; do not leak
   existence).
4. **The answer key never leaves the server before reveal.** There is exactly one student-facing
   live question endpoint and it redacts. The full-key endpoints are host-only (session) and
   owner-only (quiz). "The key" includes anything derived from it: correctness and points in an
   answer response, the per-question breakdown in results, and practice grading of a quiz that
   is being played live. A participant also never reads a question the class has not reached.
5. **CORS is an explicit allowlist** from `CORS_ORIGINS` env. No `*`.
6. **Rate limits, keyed for a classroom behind one IP:** sign-in and register 10 failed attempts
   per 15 min per (IP, email) plus a 300 per 15 min ceiling per IP; `/generate` 20/hour per
   user; everything else 600/min per signed-in user (per IP when anonymous). Return `429` with
   `Retry-After`. `X-Forwarded-For` is ignored unless `TRUST_PROXY_HOPS` says a proxy is in
   front.
7. **Body limit** 1 MB, enforced while reading, connection destroyed past it.

## Auth

Access token: JWT, HS256, 15 min TTL, claims `{sub, role, email, name, iat, exp}`.
Refresh token: opaque 256-bit random, SHA-256 hashed at rest in `refresh_tokens`, 30 day TTL,
rotated on every use, revoked on logout. Passwords: bcrypt, cost 12.

| Method | Path | Auth | Body / Notes |
|---|---|---|---|
| POST | `/auth/register` | — | `{name,email,password,role}` → `201 {accessToken,refreshToken,user}` |
| POST | `/auth/login` | — | `{email,password}` → `200 {accessToken,refreshToken,user}` |
| POST | `/auth/refresh` | — | `{refreshToken}` → `200 {accessToken,refreshToken}` (rotates) |
| POST | `/auth/logout` | Bearer | `{refreshToken}` → `204`, revokes that token |
| GET | `/auth/me` | Bearer | → `200 {user}` |
| PATCH | `/auth/me` | Bearer | `{name?}` → `200 {user}` |

`role` is `educator` or `student`. Reject anything else. Password min 8 chars.

## Content

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/content` | Bearer educator | own items only, newest first |
| POST | `/content` | Bearer educator | `{title,subject?,source_type,raw_text}` → `201` |
| POST | `/content/upload` | Bearer educator | `multipart/form-data` file field `file`; server extracts |
| GET | `/content/:id` | Bearer owner | |
| DELETE | `/content/:id` | Bearer owner | `204` |

`source_type`: `pdf|pptx|image|text`.

**Extraction is server-side and must be real.** Use `pdf-parse` (or `pdfjs-dist`) for PDF text
and a true page count from the page tree — not by counting `endobj`. Use `pizzip`/`jszip` +
`fast-xml-parser` to unzip a `.pptx` and read `ppt/slides/slideN.xml` `<a:t>` runs plus
`ppt/notesSlides/*` — a regex over compressed bytes cannot work and must not be pretended.
Images: no OCR is bundled; return `status:'needs_text'` with a clear message asking the educator
to paste the text, and say so honestly in the UI. Never claim extraction that did not happen.

`status`: `processing|ready|needs_text|failed`, with `error` populated on `failed`.

## Quizzes and questions

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/quizzes` | Bearer educator | own quizzes |
| GET | `/quizzes/published` | Bearer | published, for practice/browse |
| POST | `/quizzes` | Bearer educator | `{title,subject?,description?,content_id?}` |
| GET | `/quizzes/:id` | Bearer owner-or-published | |
| PATCH | `/quizzes/:id` | Bearer owner | `{title?,subject?,description?,scoring?}` |
| DELETE | `/quizzes/:id` | Bearer owner | `204`, cascades questions |
| POST | `/quizzes/:id/publish` | Bearer owner | `409` if <2 questions or any invalid |
| POST | `/quizzes/:id/unpublish` | Bearer owner | |
| GET | `/quizzes/:id/questions` | Bearer owner-or-published | **key for the owner only**; others get redacted questions, and `409` while a session of the quiz is open |
| POST | `/quizzes/:id/practice/answer` | Bearer owner-or-published | `{question_id, selected_index}` → `{is_correct, correct_index, explanation}`; `409` while live |
| POST | `/quizzes/:id/questions` | Bearer owner | `{questions:[...]}` appends |
| PUT | `/questions/:id` | Bearer owner | **replaces in place, keeps the id and order_index** |
| DELETE | `/questions/:id` | Bearer owner | `204`, resequences siblings |
| POST | `/quizzes/:id/questions/reorder` | Bearer owner | `{ordered_ids:[...]}` |

`PUT /questions/:id` exists specifically so "Regenerate" replaces rather than duplicating — the
previous bug. `order_index` is `UNIQUE (quiz_id, order_index)` in the schema so a duplicate is
impossible at the data layer.

Question shape:
```json
{ "id":"uuid", "quiz_id":"uuid", "question_text":"…",
  "options":["a","b","c","d"], "correct_index":0,
  "explanation":"…", "difficulty":"easy|medium|hard",
  "source_reference":"Slide 4", "order_index":0, "time_limit_seconds":20 }
```
Validate on write: exactly 4 non-empty distinct options, `correct_index` in 0..3,
`time_limit_seconds` 5..120. Reject with `422` and a field-level message.

## Generation

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/generate` | Bearer educator, 20/h | `{content_id?, source_text?, count, difficulty_mix, subject?}` |

Returns `{questions:[…]}` validated against the shape above; the key never round-trips through
the client before review. Provider `mock` (default, offline) or `anthropic`.

**Model id must be real.** Default `claude-sonnet-4-20250514`. Do not ship `claude-sonnet-5`;
it does not exist and 400s. Read `ANTHROPIC_MODEL` from env to override.

**Parse the model output properly.** Prefer a tool/JSON-schema response. If parsing text, do a
brace-matching scan that respects string literals and escapes — not `indexOf('{')` +
`lastIndexOf('}')`, which breaks on any prose containing braces. On parse failure retry up to 3
times, then return `502` with the reason. Never crash the process.

## Live sessions

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/sessions` | Bearer educator | `{quiz_id}`; host = token user; snapshots questions |
| GET | `/sessions/:id` | Bearer host-or-participant | host gets full, participant gets redacted |
| GET | `/sessions/by-code/:code` | Bearer | `{id,quiz_title,status,question_count}` only |
| POST | `/sessions/join` | Bearer student | `{join_code}`; student = token user; idempotent |
| GET | `/sessions/:id/participants` | Bearer host-or-participant | |
| GET | `/sessions/:id/questions` | **Bearer HOST ONLY** | full answer key |
| GET | `/sessions/:id/current-question` | Bearer participant-or-host | `?index=`; **redacted until revealed**; participants get `404` for any index past the current one (and in the lobby); `my_response` once revealed |
| POST | `/sessions/:id/answer` | Bearer participant | `{selected_index, question_index?}` — **no timing field**; no `is_correct`/`points_awarded` until revealed |
| POST | `/sessions/:id/start` | **Bearer HOST ONLY** | |
| POST | `/sessions/:id/reveal` | **Bearer HOST ONLY** | |
| POST | `/sessions/:id/next` | **Bearer HOST ONLY** | ends session past last question |
| POST | `/sessions/:id/end` | **Bearer HOST ONLY** | |
| GET | `/sessions/:id/results` | Bearer host-or-participant | board + own breakdown of **revealed questions only** |

Redacted question = `correct_index: -1`, `explanation: ""`.

Answer submission rules: must be the current index, phase must be `asking`, must be before
`question_ends_at` plus 750 ms grace. One scored answer per `(session, participant, question)`
enforced by a unique constraint — a second submit returns the first result, `200`, no rescore.
Scoring `base + round(speed_bonus_max * (1 - elapsed/limit))` when correct, else 0, clamped at 0.

A session auto-reveals server-side when `question_ends_at` passes, driven by one timer, so a
host closing their laptop does not freeze the class. Clients must not reveal on their own
countdown: a host device with a fast clock would cut every question short.

Join is idempotent and quiet: a re-join returns the existing participant and broadcasts nothing.
Presence (`connected`) is derived by the server from open sockets (see Realtime), not from
`POST /sessions/:id/connected`, which remains only for older clients.

## Realtime

`GET /ws?token=<accessToken>` — reject the upgrade with 401 if the token is bad.

The previous version broadcast `{channel}` to every socket and every client then refetched
everything, plus polled every 5s. That is a thundering herd. Instead:

- Client sends `{action:"subscribe", session_id}`; the socket joins **that session's room only**.
- Every frame is `{type, session_id, data, at}`. `session_id` routes it; `at` is the server's send
  time, which clients use to estimate their clock offset for countdowns.
- The server pushes **state deltas**, never "go refetch":
  - `session.state` — `{status,current_question_index,phase,question_ends_at,…}`
  - `participant.joined` — `{id,display_name}`, only when a participant row is created
  - `participant.presence` — `{id, connected}`, from sockets opening and closing (5 s grace)
  - `answer.count` — `{answered,total}`, counts only, no identities, during `asking`
  - `question.revealed` — `{question_index,correct_index,explanation,distribution:[n,n,n,n]}`
  - `answer.result` — `{question_index,selected_index,is_correct,points_awarded,…}`, **sent only to
    the answering player's own sockets**, at reveal
  - `scoreboard` — `[{participant_id,display_name,total_score,rank}]`
  - `session.ended` — `{…}`
- Answer-count updates coalesce on a 250 ms tick, so 50 simultaneous answers produce ~1 message.
- Heartbeat ping every 30s; drop dead sockets. Clients may send `{action:"ping"}` and get a
  `pong` frame; they should, to detect half-open links.
- A socket is closed with code **4001** when the access token it opened with expires. Clients
  refresh the token and reconnect immediately. Client frames are capped at 64 KB.
- **The client must not poll.** Refetch only on socket reconnect, to resync once; a reveal
  needs no request at all.

## Errors

```json
{ "error": { "code": "FORBIDDEN", "message": "human readable", "field": "email" } }
```
Codes: `VALIDATION`, `UNAUTHORIZED`, `FORBIDDEN`, `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`,
`UPSTREAM`, `INTERNAL`. Never leak stack traces. Log with a request id, return the id on 500.

## Postgres schema

Real migrations in `backend/migrations/NNN_*.sql`, applied by `npm run migrate`. UUID v4 keys
(`gen_random_uuid()`, `pgcrypto`).

```
users(id pk, name, email citext unique, password_hash, role, created_at)
refresh_tokens(id pk, user_id fk->users cascade, token_hash unique, expires_at, revoked_at, created_at)
content_items(id pk, owner_id fk->users cascade, title, subject, source_type, status,
              extracted_text, page_count, file_name, error, created_at)
quizzes(id pk, owner_id fk->users cascade, title, subject, description, content_id fk->content_items set null,
        status, base_points int default 500, speed_bonus_max int default 500, created_at, updated_at)
questions(id pk, quiz_id fk->quizzes cascade, question_text, options jsonb, correct_index int,
          explanation, difficulty, source_reference, order_index int, time_limit_seconds int,
          UNIQUE(quiz_id, order_index) DEFERRABLE INITIALLY DEFERRED)
quiz_sessions(id pk, quiz_id fk->quizzes, host_id fk->users, quiz_title, join_code unique,
              status, current_question_index int default -1, total_questions int, phase,
              question_started_at, question_ends_at, started_at, ended_at, allow_late_join bool,
              created_at)
session_questions(id pk, session_id fk->quiz_sessions cascade, order_index int, question_text,
                  options jsonb, correct_index int, explanation, difficulty, time_limit_seconds,
                  UNIQUE(session_id, order_index))
session_participants(id pk, session_id fk->quiz_sessions cascade, user_id fk->users,
                     display_name, total_score int default 0, correct_count int default 0,
                     answered_count int default 0, streak int default 0, connected bool,
                     joined_at, UNIQUE(session_id, user_id))
responses(id pk, session_id fk->quiz_sessions cascade, participant_id fk->session_participants cascade,
          session_question_id fk->session_questions, question_index int, selected_index int,
          is_correct bool, response_time_ms int, points_awarded int, answered_at,
          UNIQUE(participant_id, question_index))
```

Sessions snapshot their questions into `session_questions` so editing a quiz mid-session cannot
change what is being played. Leaderboard and analytics are SQL aggregates over `responses` and
`session_participants` — no denormalised cumulative table, so `period` filters actually work
(the previous version accepted `period` and ignored it).

## Config

`backend/.env` (gitignored, `.env.example` committed):
```
PORT=8787
DATABASE_URL=postgres://localhost:5432/quizzle
JWT_SECRET=<32+ random bytes>
CORS_ORIGINS=http://localhost:8090,http://localhost:5000
AI_PROVIDER=mock
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=claude-sonnet-4-20250514
TRUST_PROXY_HOPS=0          # set to the number of reverse proxies in front, never higher
RATE_LIMIT_AUTH=10          # failed sign-ins per (IP, email) per 15 min
RATE_LIMIT_AUTH_IP=300      # all sign-ins/registrations per IP per 15 min
RATE_LIMIT_GLOBAL=600       # requests per signed-in user per minute
PRESENCE_GRACE_MS=5000
WS_MAX_PAYLOAD_BYTES=65536
```
Fail fast at boot with a clear message if `JWT_SECRET` or `DATABASE_URL` is missing. Handle
`EADDRINUSE` with a readable message naming the port, not a stack trace.

## Flutter client notes

- The `Backend` interface in `lib/data/repositories.dart` stays the seam. Screens keep using the
  same providers; only the implementation changes.
- Tokens in `flutter_secure_storage` where available, `shared_preferences` as web fallback.
  **Never** persist passwords client-side — the old in-memory backend did and must stop.
- A single Dio interceptor refreshes on `401` once, queues concurrent failures, and signs out
  only if the server **rejects** the refresh — a refresh that cannot reach the server leaves the
  session alone.
- The WebSocket authenticates outside that interceptor, so the realtime client refreshes before
  opening a socket when the access token expires within 60 s, and once more after a refused
  upgrade or a `4001` close.
- The offline/in-memory backend stays for tests and zero-setup demo but **must not** be sold as
  multi-device, and must stop writing credentials to local storage.
