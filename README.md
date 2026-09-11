# quizzle

Turn any lecture material — a PDF, a slide deck, a photo of a whiteboard — into a
live, gamified quiz in minutes. Educators upload content, questions are generated
and reviewed, then students join with a code and compete on a live leaderboard.

One Flutter codebase targets **Android, Windows, macOS, Linux and Web**.

---

## Quick start (zero setup)

```bash
flutter pub get
flutter run --dart-define-from-file=dart_define.json      # any device, or:
flutter run -d chrome --dart-define-from-file=dart_define.json
```

`dart_define.json` ships with `BACKEND=memory` and `AI=mock`, so the whole app
runs offline with no accounts, no server and no API keys. On the sign-in screen,
use **Continue as Educator / Student** for one-tap demo logins, or register real
local accounts. A demo quiz ("The Cell — Quick Check") is seeded so you can host
a live session immediately.

Every account, quiz, question and score is saved to local storage (browser
`localStorage` on web, a local file elsewhere) and is restored automatically —
reloading the page or restarting the app brings back who was signed in and
everything they created, with no re-login required. Sign out to clear the saved
session; each browser/device keeps its own store.

> In `memory` mode the host and students must be in the **same running app
> instance** (e.g. one desktop window) because live state lives in one process.
> Everything *else* (accounts, quizzes, scores) is saved locally per the above —
> it's specifically the in-progress live session that needs the same process.
> For a real multi-device live session, run the bundled backend — see below.

## Real multi-device live sessions (Node backend)

```bash
cd backend
npm install
npm start                     # http://localhost:8787
```

Then run the app against it:

```bash
flutter run --dart-define=BACKEND=remote --dart-define=API_BASE=http://localhost:8787
```

Now open the app on several devices on the same network (point `API_BASE` at the
host machine's LAN IP for phones). One person hosts, everyone else joins with the
code. Live updates arrive over a single WebSocket. This server is also the
starting point for the "custom backend" option in the spec (Section 6).

The server writes everything to `backend/data.json`, so accounts and quizzes
survive an `npm start` restart too, not just a page reload (which already
worked, since this backend's data lives on the server, not the browser tab).
The client remembers its login token locally, so a reload doesn't force a
re-login either. Delete `data.json` to reset the server to empty.

## Real AI question generation

Generation runs **server-side** so the API key never ships in a client build
(spec Section 13). With the Node backend running:

```bash
cd backend
cp .env.example .env
#   AI=anthropic
#   ANTHROPIC_API_KEY=sk-ant-...
#   ANTHROPIC_MODEL=claude-sonnet-5
npm start
```

For quick local prompt iteration only, the Flutter client can also call Claude
directly with `--dart-define=AI=anthropic --dart-define=ANTHROPIC_API_KEY=...`
(see `lib/ai/anthropic_quiz_generator.dart`, which is clearly marked dev-only).

---

## Configuration

All config comes from `--dart-define` / `--dart-define-from-file` — nothing
secret is committed. `dart_define.json` is gitignored; `dart_define.example.json`
is the template.

| Key | Values | Meaning |
|---|---|---|
| `BACKEND` | `memory` (default), `remote` | In-process store vs. the Node server |
| `API_BASE` | URL | Node server base URL when `remote` |
| `AI` | `mock` (default), `anthropic` | Offline sample generator vs. Claude |
| `ANTHROPIC_API_KEY` | string | Dev-only direct client key; prefer the server |
| `ANTHROPIC_MODEL` | string | Default `claude-sonnet-5` |

## Project layout

```
lib/
  app/            routing (go_router), theme
  core/           env, ids/join codes, responsive helpers, failures
  models/         data model (spec Section 8) with JSON + validation
  data/
    repositories.dart      backend-agnostic contracts
    in_memory/             default backend, broadcast-stream "realtime"
    remote/                talks to backend/ over REST + WebSocket
  ai/             QuizGenerator: mock / server / dev-direct + extraction + schema validation
  state/          Riverpod providers and controllers
  features/       auth, home, content, quiz_management, live_session, leaderboard, analytics, profile
  shared_widgets/ scaffold, option grid, countdown ring, leaderboard/podium, async views
backend/          Node reference server (REST + ws), mirrors the same logic
docs/             assumptions log, Firebase implementation guide
test/             scoring, generation/validation, full live-session flow
```

## What works

- **Phase 1** — auth with roles; upload PDF/PPTX/image or paste text; client-side
  text extraction (best-effort; full extraction is server-side); pick count +
  difficulty mix; generate; review/edit/regenerate/reorder questions, per-question
  timers; publish. Generator output is validated against the Section 7 schema and
  rejected on malformed data.
- **Phase 2** — "Go Live" issues a 6-char join code; deep link `/join/<code>`;
  lobby; synchronized question push + countdown from a shared deadline;
  Kahoot-style scoring (base + decaying speed bonus, wrong = 0, editable per
  quiz); reveal with answer distribution; live session leaderboard; podium and
  per-student breakdown; reconnect resumes at the current question with score
  intact (answer submission is idempotent).
- **Phase 3 (partial)** — global/all-time leaderboard with weekly/all-time
  toggle; educator analytics (avg score, avg correct rate, completion, hardest
  question, per-question bar chart). Streaks are tracked and shown; badges are
  not implemented.
- **Responsive** — bottom nav on phones, side rail on desktop/web; capped
  content width on large screens; no fixed mobile-only layouts.

## Not done / known limitations

- `memory` backend is single-process (fine for one device / tests / review).
- Client-side PDF/PPTX extraction only reads uncompressed text; images have no
  on-device OCR. The Node server is where real extraction belongs (stubbed to
  pass text through today).
- No Firebase implementation is wired in (see `docs/BACKEND_FIREBASE.md` for the
  ready-to-drop-in version and rationale).
- Desktop (Windows/Linux) and macOS builds are enabled as targets but were not
  compiled here (this machine has no full Xcode; Windows/Linux need their own
  hosts). Web and Android build clean.
- Badges, self-paced practice scoring, multi-tenant/institution model: not built.

See `docs/ASSUMPTIONS.md` for every open decision from spec Section 15 and what
was assumed.

## Tests

```bash
flutter test
```

Covers scoring maths, AI-output schema validation, an end-to-end live session
(join → host advance → answer → reveal → score → leaderboard, including
answer-key protection and double-submit safety), app boot/navigation/dark mode,
and that a registered account plus everything it created survives a simulated
restart.
