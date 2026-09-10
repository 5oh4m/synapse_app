# quizzle backend (reference)

Node reference server for real multi-device live sessions. Implements the same
logic as the Flutter `InMemoryBackend`, exposed over REST + one WebSocket for
live updates. State is in memory — restart clears it. This is the concrete
starting point for the spec's "custom Node.js backend" option (Section 6).

## Run

```bash
npm install
npm start            # http://localhost:8787  (PORT env to change)
```

Only dependency: `ws`. Node 20+.

## Point the app at it

```bash
flutter run \
  --dart-define=BACKEND=remote \
  --dart-define=API_BASE=http://<this-machine-ip>:8787
```

## AI generation

`.env` (copy from `.env.example`, never commit the real key):

```
AI=anthropic
ANTHROPIC_API_KEY=sk-ant-...
ANTHROPIC_MODEL=claude-sonnet-5
```

`AI=mock` (default) uses an offline cloze generator. A failed Claude call falls
back to mock so a demo never hard-blocks. All generator output — mock or Claude —
is validated against the spec Section 7 schema before it is returned.

## Endpoints

`GET /health` · auth `POST /auth/{register,login,logout}` `PUT /auth/profile` ·
content `GET|POST /content` `GET|DELETE /content/:id` ·
quizzes `GET|POST /quizzes` `GET /quizzes/published` `GET|PUT|DELETE /quizzes/:id`
`GET|POST /quizzes/:id/questions` `POST /quizzes/:id/questions/reorder`
`POST /quizzes/:id/{publish,unpublish}` `PUT|DELETE /questions/:id` ·
generation `POST /generate` ·
sessions `POST /sessions` `GET /sessions/:id` `GET /sessions/by-code/:code`
`GET /sessions/:id/{participants,responses,questions}`
`GET /sessions/:id/questions/:index/public`
`POST /sessions/join` `POST /sessions/:id/{connected,start,reveal,next,end,answer}` ·
`GET /leaderboard/global` · `GET /analytics/quiz/:id` · `GET /analytics/student/:id` ·
`WS /ws` → `{ "channel": "session:<id>" | "quizzes" | "content" | "leaderboard" }`

## For production

Swap the `db` Maps for Postgres, move the WS fan-out to Redis pub/sub, put real
auth on the routes, and move generation + scoring authority into the same place.
The route contract does not need to change.
