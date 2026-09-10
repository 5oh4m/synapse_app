# Assumptions & open decisions (spec Section 15)

Per Section 16.1, unresolved items were built with a stated assumption and
flagged here rather than blocking.

| # | Decision | Assumption taken | Where it bites | How to change |
|---|---|---|---|---|
| 1 | Backend | **Repository abstraction** with an in-memory default and a bundled Node reference server (`backend/`). Firebase is documented, not wired. | `lib/data/` | Add a `FirebaseBackend implements Backend` (see `docs/BACKEND_FIREBASE.md`) and switch `backendProvider`. |
| 2 | AI provider | **Claude** (`claude-sonnet-5`), called **server-side** in `backend/`. Offline `mock` generator is the default so nothing is required to run. | `lib/ai/`, `backend/src/server.mjs` | Set `AI=anthropic` + key in `backend/.env`, or implement a Gemini path in `generateQuestions()`. |
| 3 | "Website" | The Flutter **Web** build of the same app. No separate web codebase. | `web/` | Deploy `flutter build web`. |
| 4 | Live vs self-paced | **Live is primary.** Self-paced practice is stubbed (students can browse published quizzes; solo scoring is not implemented). | `lib/features/home` | Add a practice runner reusing `OptionGrid` + `ScoringConfig`. |
| 5 | Scale | Sized for **~100 concurrent students per session** (spec NFR). In-memory and the single-process Node server handle that comfortably; no load test was run. | `backend/` | Move to Postgres + Redis pub/sub for the WS fan-out; keep the same routes. |
| 6 | Institution model | **Single-tenant.** Each educator owns their own content/quizzes; no orgs/classes/admins. | `lib/models/` (no `org_id`) | Add `org_id` to users/quizzes/sessions and an org scope to queries. |

## Other implementation choices not in the spec

- **Join code**: 6 chars, alphabet excludes `0/O/1/I` for readability on a projector.
- **Scoring**: `points = base + speedBonusMax * (timeLeft / timeLimit)` for a
  correct answer, `0` otherwise; defaults `base=500`, `speedBonusMax=500`;
  editable per quiz via `ScoringConfig`. Answers after the deadline score `0`.
- **Answer-key safety**: students fetch questions through a "public" endpoint
  that strips `correct_index` and `explanation` until the host reveals.
- **Reconnect**: `submitAnswer` is idempotent per `(session, student, question
  index)`, so a rejoin never double-scores and resumes at the current question.
- **State management**: Riverpod (spec's first suggestion).
- **No code generation**: models are hand-written `fromJson`/`toJson` to keep the
  build toolchain minimal (no `build_runner`).
