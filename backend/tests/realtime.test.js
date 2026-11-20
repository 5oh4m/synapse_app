// The WebSocket hub, over a real socket. Each test file runs in its own process,
// so the short presence grace below does not leak into other suites.
process.env.PRESENCE_GRACE_MS = '150';

import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import WebSocket from 'ws';

const h = await import('./helpers.js');
const { attachHub, closeHub, CLOSE_TOKEN_EXPIRED } = await import('../src/realtime/hub.js');
const { signAccessToken } = await import('../src/services/auth.service.js');
const { config } = await import('../src/config.js');

let server;
let port;

before(async () => {
  await h.resetDb();
  server = http.createServer(h.app);
  attachHub(server);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
});
beforeEach(h.resetDb);
after(async () => {
  await closeHub();
  await new Promise((resolve) => server.close(resolve));
  await h.shutdown();
});

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Opens a socket and records every frame it receives. */
function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${token}`);
    const frames = [];
    const closed = new Promise((done) => ws.on('close', (code) => done(code)));
    ws.on('message', (raw) => frames.push(JSON.parse(String(raw))));
    ws.on('open', () => resolve({ ws, frames, closed }));
    ws.on('error', reject);
  });
}

async function subscribe(sock, sessionId) {
  sock.ws.send(JSON.stringify({ action: 'subscribe', session_id: sessionId }));
  for (let i = 0; i < 40; i += 1) {
    if (sock.frames.some((f) => f.type === 'subscribed')) return;
    await wait(10);
  }
  throw new Error('subscribe timed out');
}

const ofType = (sock, type) => sock.frames.filter((f) => f.type === type);

async function liveRoom({ students = 2 } = {}) {
  const educator = await h.makeUser({ role: 'educator' });
  const players = [];
  for (let i = 0; i < students; i += 1) {
    players.push(await h.makeUser({ role: 'student', name: `Player ${i + 1}` }));
  }
  const { quiz } = await h.makePublishedQuiz(educator, { count: 2 });
  const { session } = await h.makeLiveSession(educator, quiz.id, players);
  return { educator, players, session };
}

describe('realtime hub', () => {
  test('every frame names the session it belongs to', async () => {
    const { educator, session } = await liveRoom();
    const host = await connect(educator.accessToken);
    await subscribe(host, session.id);
    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await wait(100);
    const state = ofType(host, 'session.state').at(-1);
    assert.equal(state.session_id, session.id);
    host.ws.close();
  });

  test('a re-join does not broadcast the scoreboard', async () => {
    const { educator, players, session } = await liveRoom();
    const host = await connect(educator.accessToken);
    await subscribe(host, session.id);
    for (let i = 0; i < 3; i += 1) {
      await players[0].post('/api/sessions/join').send({ join_code: session.join_code });
    }
    await wait(100);
    assert.equal(ofType(host, 'scoreboard').length, 0, 'each re-join pushed a scoreboard');
    assert.equal(ofType(host, 'participant.joined').length, 0);
    host.ws.close();
  });

  test('at reveal each player receives only their own result', async () => {
    const { educator, players, session } = await liveRoom();
    const host = await connect(educator.accessToken);
    const a = await connect(players[0].accessToken);
    const b = await connect(players[1].accessToken);
    for (const s of [host, a, b]) await subscribe(s, session.id);

    await educator.post(`/api/sessions/${session.id}/start`).send({});
    await players[0].post(`/api/sessions/${session.id}/answer`).send({ selected_index: 0 });
    await players[1].post(`/api/sessions/${session.id}/answer`).send({ selected_index: 2 });
    await educator.post(`/api/sessions/${session.id}/reveal`).send({});
    await wait(150);

    const mineA = ofType(a, 'answer.result');
    const mineB = ofType(b, 'answer.result');
    assert.equal(mineA.length, 1);
    assert.equal(mineA[0].data.is_correct, true);
    assert.ok(mineA[0].data.points_awarded > 0);
    assert.equal(mineB.length, 1);
    assert.equal(mineB[0].data.is_correct, false);
    assert.equal(ofType(host, 'answer.result').length, 0, 'the host socket got player results');
    for (const s of [host, a, b]) s.ws.close();
  });

  test('presence follows the socket: connected on subscribe, disconnected after it closes', async () => {
    const { educator, players, session } = await liveRoom({ students: 1 });
    await h.query('UPDATE session_participants SET connected = false WHERE session_id = $1', [session.id]);
    const host = await connect(educator.accessToken);
    await subscribe(host, session.id);

    const player = await connect(players[0].accessToken);
    await subscribe(player, session.id);
    await wait(100);
    let row = await h.query('SELECT id, connected FROM session_participants WHERE session_id = $1', [session.id]);
    assert.equal(row.rows[0].connected, true);

    player.ws.close();
    await wait(400);
    row = await h.query('SELECT connected FROM session_participants WHERE session_id = $1', [session.id]);
    assert.equal(row.rows[0].connected, false, 'a closed socket still counted as connected');
    const presence = ofType(host, 'participant.presence').map((f) => f.data.connected);
    assert.deepEqual(presence, [true, false]);
    host.ws.close();
  });

  test('a socket is closed when the access token it opened with expires', async () => {
    const { educator } = await liveRoom({ students: 0 });
    const saved = config.accessTtlSeconds;
    config.accessTtlSeconds = 1;
    const shortLived = signAccessToken({
      id: educator.id,
      role: 'educator',
      email: educator.email,
      name: educator.name,
    });
    config.accessTtlSeconds = saved;
    const sock = await connect(shortLived);
    const code = await Promise.race([sock.closed, wait(3000).then(() => 'still open')]);
    assert.equal(code, CLOSE_TOKEN_EXPIRED);
  });

  test('an oversized client frame closes the socket', async () => {
    const { educator } = await liveRoom({ students: 0 });
    const sock = await connect(educator.accessToken);
    sock.ws.send('x'.repeat(config.wsMaxPayloadBytes + 1));
    const code = await Promise.race([sock.closed, wait(2000).then(() => 'still open')]);
    assert.equal(code, 1009);
  });

  test('a subscribe with a non-UUID session id is refused without a query', async () => {
    const { educator } = await liveRoom({ students: 0 });
    const sock = await connect(educator.accessToken);
    sock.ws.send(JSON.stringify({ action: 'subscribe', session_id: 'nope' }));
    await wait(100);
    assert.equal(ofType(sock, 'error')[0].data.code, 'VALIDATION');
    sock.ws.close();
  });
});
