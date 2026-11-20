# quizzle

Turn lecture material — a PDF, a slide deck, pasted notes — into a live, gamified quiz.
Educators upload content, generate and review questions, then run a live session: students
join from their own phones with a code or QR, answer against a countdown, and compete on a
live leaderboard.

One Flutter codebase (Android, iOS, web, macOS, Windows, Linux) plus a Node + PostgreSQL
server for real multi-device play.

---

## Two ways to run

| | Offline demo | Classroom |
|---|---|---|
| Client flag | `BACKEND=memory` (default) | `BACKEND=remote` |
| Server | none | `backend/` (Express, PostgreSQL, JWT, WebSocket) |
| Multi-device | no — host and players share one running app | yes |
| Accounts | local profiles, no passwords stored | real accounts, bcrypt |
| Use it for | trying the flow, tests, design review | anything with more than one device |

## Quick start: offline demo

Requires Flutter **3.47 or newer** (see [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md)).

```bash
flutter pub get
cp dart_define.example.json dart_define.json
flutter run -d chrome --dart-define-from-file=dart_define.json
```

On the sign-in screen use **Educator** or **Student** under "Or jump straight in". A demo
library item and quiz ("The Cell — Quick Check") are seeded, so an educator can go live
straight away. Data is kept in local storage and restored on reload. Passwords are never
stored on the device, so after signing out a local account cannot sign back in with a
password — use the demo buttons, or the classroom setup.

In this mode a live session only works inside the same running app instance.

## Classroom setup

### 1. Server

Requires Node **20+** and PostgreSQL (16 is what this repo is tested on).

```bash
cd backend
npm install
cp .env.example .env
# set JWT_SECRET (32+ random bytes):
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
createdb quizzle
npm run migrate          # applies backend/migrations
npm run seed             # optional demo data
npm start                # http://localhost:8787/api, WebSocket at /ws
```

`npm run seed` creates `demo.educator@quizzle.app` and `demo.student@quizzle.app`
(password `demo-password-1`) plus a published five-question quiz. `npm run dev` restarts on
file changes; `npm run db:reset` drops, recreates, migrates and seeds the database (it refuses
anything but a local host).

The server refuses to start without `DATABASE_URL` or `JWT_SECRET` and says why.

### 2. App

```bash
flutter run -d chrome --web-port 8090 \
  --dart-define=BACKEND=remote \
  --dart-define=API_BASE=http://localhost:8787
```

Browser origins must be listed in `CORS_ORIGINS` in `backend/.env` (the example already
allows `http://localhost:8090`).

### 3. Phones on the classroom network

Serve the web app on the LAN and point it at the machine running the server:

```bash
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8090 \
  --dart-define=BACKEND=remote \
  --dart-define=API_BASE=http://<server-lan-ip>:8787
```

Add `http://<server-lan-ip>:8090` to `CORS_ORIGINS` and restart the server. The host opens
**Go Live** on a published quiz; the lobby shows the join code, a join link and a QR code.

### Question generation

Generation always runs on the server, so no API key ships in the app. The default provider
is `mock` (offline). For Claude, set in `backend/.env`:

```
AI_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
ANTHROPIC_MODEL=claude-sonnet-4-20250514
```

Output is validated (four distinct options, a valid answer index, time limit 5–120 s) and
retried before anything reaches the review screen. Generation is limited to 20 requests an
hour per educator.

---

## Configuration

### App (`--dart-define`)

| Key | Default | Meaning |
|---|---|---|
| `BACKEND` | `memory` | `memory` (offline) or `remote` (the server) |
| `API_BASE` | `http://localhost:8787` | Server origin; REST is under `/api`, the socket is `/ws` |
| `APP_URL` | page origin on web | Public origin used in join links and QR codes; set it for native builds |
| `AI` | `mock` | Label for the "how questions are generated" banner; the server decides the provider |
| `ANTHROPIC_MODEL` | `claude-sonnet-4-20250514` | Label only |

`dart_define.json` is gitignored; copy it from `dart_define.example.json`.

### Server (`backend/.env`)

| Key | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | — | Required |
| `JWT_SECRET` | — | Required, 32+ random bytes |
| `PORT` | `8787` | |
| `CORS_ORIGINS` | none | Comma-separated browser origins; no wildcard |
| `ACCESS_TTL_SECONDS` / `REFRESH_TTL_DAYS` | `900` / `30` | Token lifetimes |
| `AI_PROVIDER` | `mock` | `mock` or `anthropic` |
| `RATE_LIMIT_AUTH` / `RATE_LIMIT_AUTH_IP` | `10` / `300` | Failed sign-ins per account and IP, and all sign-ins per IP, per 15 min |
| `RATE_LIMIT_GLOBAL` | `600` | Requests per signed-in user per minute |
| `TRUST_PROXY_HOPS` | `0` | Reverse proxies in front; leave at 0 without one |

The full list, with comments, is in [backend/.env.example](backend/.env.example).

## Deploying the web app

Path URLs (`/join/ABC123`) need the host to serve `index.html` for unknown paths, WebSocket
upgrades must reach `/ws`, and `og:image` needs an absolute URL. Build flags and proxy
settings are in [docs/DEPLOY.md](docs/DEPLOY.md).

---

## What's in the app

**Educators** — content library with server-side extraction (PDF text and real page count,
PPTX slide and notes text; images ask for pasted text because no OCR is bundled); generate
questions with a count and difficulty mix; review, edit, regenerate in place and reorder;
per-question time limits and scoring; publish; quiz analytics.

**Live session** — six-character join code, join link and QR code; lobby with live presence;
questions pushed over one WebSocket; countdown to a server deadline; the server closes each
question and scores it (base points plus a speed bonus measured on the server); reveal with
answer distribution and each player's own result; leaderboard with rank changes; podium and
per-question breakdown at the end. On projector-width screens the question and the standings
sit side by side; on phones the submit button stays pinned to the bottom edge.

**Students** — join by code, link or QR; self-paced practice on published quizzes, graded
by the server; play history; global leaderboard for this week or all time.

**Design** — a Bauhaus design system in light and dark themes, with contrast-checked colours,
screen-reader labels and live regions, and motion that respects reduced-motion settings.
See [docs/DESIGN.md](docs/DESIGN.md).

## Security model

- Identity comes only from the access token, never from a request body.
- Every mutation checks ownership; the wrong owner gets `404`.
- The answer key is server-side until reveal: students get redacted questions, no
  correctness in answer responses, and nothing past the current question.
- Timing and scoring are measured on the server; resubmitting never rescores.
- bcrypt passwords, 15-minute access tokens, rotating refresh tokens, CORS allowlist, body
  limits, and rate limits sized for a class sharing one IP.

The rules and every endpoint are in [docs/API.md](docs/API.md).

---

## Project layout

```
lib/
  app/             router, theme, motion system, page transitions
  core/            env, connection state, server clock, ids/join codes, responsive helpers
  models/          data model with JSON mapping
  data/
    repositories.dart   the Backend interface every screen talks to
    in_memory/          offline backend
    remote/             REST client with token refresh, realtime client, session channels
    local/              token and key-value storage
  ai/              generation and extraction clients, output validation
  state/           Riverpod providers and controllers
  features/        auth, home, content, quiz_management, live_session, leaderboard,
                   analytics, profile
  shared_widgets/  answer tiles, countdown, leaderboard and podium, buttons, cards
backend/
  src/             app wiring, routes, services, realtime hub, db, middleware
  migrations/      SQL migrations
  scripts/         migrate, seed, db reset, test runner
  tests/           API, realtime, rate-limit and extraction tests
docs/              API contract, design system, state contract, deploy, toolchain
test/              Flutter unit, widget and regression tests
web/               web shell, manifest, link-preview tags
```

## Tests

```bash
# Flutter
flutter test
dart analyze lib test     # `flutter analyze` is broken on some machines; see docs/TOOLCHAIN.md

# Server (needs PostgreSQL)
cd backend
npm test
```

The server tests run against a separate database named in `backend/.env.test`, which must
contain `test` in its name. The runner creates and migrates it and empties it before each
test. A minimal `.env.test`:

```
DATABASE_URL=postgres://localhost:5432/quizzle_test
BCRYPT_COST=4
RATE_LIMIT_AUTH=10000
RATE_LIMIT_AUTH_IP=100000
RATE_LIMIT_GENERATE=10000
RATE_LIMIT_GLOBAL=100000
```

`JWT_SECRET` is read from `.env` when `.env.test` does not set it.

What the suites cover: authorization for every host control and owned resource, server-side
timing and double-submit safety, the answer-key rules, extraction, leaderboard filters, the
realtime hub (per-player frames, presence, token expiry), classroom rate limits, scoring,
generation validation, token refresh and reconnect in the client, the live screens' reveal
and animations, and phone and projector layouts.

## Known limitations

- **One server instance.** Realtime rooms, presence and the auto-reveal timer live in a single
  Node process. Running several instances needs a shared pub/sub layer, which is not built.
- **Web token storage.** On web the refresh token is kept in `localStorage`, and the socket
  sends its access token in the URL.
- **No OCR.** Image uploads ask the educator to paste the text.
- **Not built:** badges, a subject filter in the leaderboard UI (the API supports it), an
  institution/class model, and the Firebase backend described in
  [docs/BACKEND_FIREBASE.md](docs/BACKEND_FIREBASE.md).
- **Platforms.** The web app is the primary target. Native desktop and mobile builds are
  configured but not regularly verified.

Earlier design decisions and assumptions are recorded in [docs/ASSUMPTIONS.md](docs/ASSUMPTIONS.md).
