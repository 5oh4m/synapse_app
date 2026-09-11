// Per-session rooms pushing state deltas.
//
// Defect fixed: the old server kept one flat Set of sockets and sent
// `{channel:"session:<id>"}` to every one of them, which every client answered
// by refetching the session, the participants and the responses. 50 students
// answering one question produced ~2500 HTTP requests. Here:
//   - a socket joins exactly one room per `subscribe`, after an authorization
//     check against quiz_sessions / session_participants;
//   - the server sends the new state, never "go refetch";
//   - answer.count is coalesced on a 250 ms tick, so 50 simultaneous answers
//     produce about one frame;
//   - a 30 s ping/pong reaps dead sockets.
import { WebSocketServer } from 'ws';
import { config } from '../config.js';
import { log } from '../log.js';
import { userFromToken } from '../middleware/auth.js';
import { sessionJson } from '../util/serialize.js';
import { answerCounts, getSessionAccess } from '../services/session.queries.js';

/** sessionId -> Set<WebSocket> */
const rooms = new Map();
/** sessionIds needing an answer.count frame on the next tick. */
const dirtyCounts = new Set();
/** sessionId -> current_question_index, so the coalescing tick stays query-light. */
const roomIndex = new Map();
export const noteCurrentIndex = (sessionId, index) => roomIndex.set(sessionId, index);

let wss = null;
let coalesceTimer = null;
let heartbeatTimer = null;

function roomFor(sessionId) {
  let set = rooms.get(sessionId);
  if (!set) {
    set = new Set();
    rooms.set(sessionId, set);
  }
  return set;
}

function send(ws, type, data) {
  if (ws.readyState !== ws.OPEN) return;
  try {
    ws.send(JSON.stringify({ type, data, at: new Date().toISOString() }));
  } catch (err) {
    log.warn('ws send failed', { message: err.message });
  }
}

/** Fan a delta out to one session's room only. */
export function emitTo(sessionId, type, data) {
  const set = rooms.get(sessionId);
  if (!set || set.size === 0) return 0;
  const frame = JSON.stringify({ type, data, at: new Date().toISOString() });
  let n = 0;
  for (const ws of set) {
    if (ws.readyState !== ws.OPEN) continue;
    try {
      ws.send(frame);
      n += 1;
    } catch {
      /* socket is going away; the close handler cleans up */
    }
  }
  return n;
}

export function emitSessionState(session) {
  noteCurrentIndex(session.id, session.current_question_index);
  return emitTo(session.id, 'session.state', sessionJson(session));
}

export const emitParticipantJoined = (sessionId, participant) =>
  emitTo(sessionId, 'participant.joined', {
    id: participant.id,
    display_name: participant.display_name,
  });

export const emitQuestionRevealed = (sessionId, payload) =>
  emitTo(sessionId, 'question.revealed', payload);

export const emitScoreboard = (sessionId, rows) => emitTo(sessionId, 'scoreboard', rows);

export const emitSessionEnded = (sessionId, payload) => emitTo(sessionId, 'session.ended', payload);

/**
 * Mark a session's answer count dirty. The actual frame goes out on the shared
 * 250 ms tick, so a burst of answers collapses into one message.
 */
export function queueAnswerCount(sessionId) {
  if (!rooms.has(sessionId)) return;
  dirtyCounts.add(sessionId);
}

async function flushAnswerCounts() {
  if (dirtyCounts.size === 0) return;
  const ids = [...dirtyCounts];
  dirtyCounts.clear();
  for (const sessionId of ids) {
    const set = rooms.get(sessionId);
    if (!set || set.size === 0) continue;
    try {
      // The index is read from the room's cached session state, kept current by
      // every session.state emit, so the tick does not need a second query.
      const index = roomIndex.get(sessionId);
      if (index === undefined || index < 0) continue;
      const counts = await answerCounts(sessionId, index);
      emitTo(sessionId, 'answer.count', counts);
    } catch (err) {
      log.warn('answer.count flush failed', { session_id: sessionId, message: err.message });
    }
  }
}

export function attachHub(server) {
  wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    let url;
    try {
      url = new URL(req.url, 'http://localhost');
    } catch {
      return socket.destroy();
    }
    if (url.pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return socket.destroy();
    }
    // docs/API.md: reject the upgrade with 401 when the token is bad.
    const token = url.searchParams.get('token') || '';
    const user = userFromToken(token);
    if (!user) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      return socket.destroy();
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.user = user;
      ws.joined = new Set();
      ws.isAlive = true;
      wss.emit('connection', ws, req);
    });
  });

  wss.on('connection', (ws) => {
    send(ws, 'hello', { user_id: ws.user.sub, heartbeat_ms: config.heartbeatMs });

    ws.on('pong', () => {
      ws.isAlive = true;
    });

    ws.on('message', async (raw) => {
      let msg;
      try {
        msg = JSON.parse(String(raw));
      } catch {
        return send(ws, 'error', { code: 'VALIDATION', message: 'Frames must be JSON.' });
      }
      if (msg?.action === 'ping') return send(ws, 'pong', {});
      if (msg?.action === 'unsubscribe') {
        leave(ws, msg.session_id);
        return send(ws, 'unsubscribed', { session_id: msg.session_id });
      }
      if (msg?.action !== 'subscribe') {
        return send(ws, 'error', { code: 'VALIDATION', message: 'Unknown action.' });
      }
      const sessionId = msg.session_id;
      if (typeof sessionId !== 'string' || !sessionId) {
        return send(ws, 'error', { code: 'VALIDATION', message: 'session_id is required.' });
      }
      try {
        const access = await getSessionAccess(sessionId, ws.user.sub);
        if (!access || (!access.isHost && !access.participantId)) {
          // Same 404 shape as REST: do not leak that the session exists.
          return send(ws, 'error', { code: 'NOT_FOUND', message: 'Session not found.' });
        }
        roomFor(sessionId).add(ws);
        ws.joined.add(sessionId);
        noteCurrentIndex(sessionId, access.session.current_question_index);
        send(ws, 'subscribed', { session_id: sessionId, role: access.isHost ? 'host' : 'participant' });
        // One resync frame on subscribe. The client then waits for deltas and
        // must not poll.
        send(ws, 'session.state', sessionJson(access.session));
      } catch (err) {
        log.warn('ws subscribe failed', { message: err.message });
        send(ws, 'error', { code: 'INTERNAL', message: 'Could not subscribe.' });
      }
    });

    const cleanup = () => {
      for (const sessionId of ws.joined) leave(ws, sessionId);
      ws.joined.clear();
    };
    ws.on('close', cleanup);
    ws.on('error', cleanup);
  });

  heartbeatTimer = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch {
        ws.terminate();
      }
    }
  }, config.heartbeatMs);
  heartbeatTimer.unref?.();

  coalesceTimer = setInterval(() => {
    flushAnswerCounts().catch((err) => log.warn('coalesce tick', { message: err.message }));
  }, config.answerCoalesceMs);
  coalesceTimer.unref?.();

  return wss;
}

function leave(ws, sessionId) {
  const set = rooms.get(sessionId);
  if (!set) return;
  set.delete(ws);
  if (set.size === 0) {
    rooms.delete(sessionId);
    roomIndex.delete(sessionId);
    dirtyCounts.delete(sessionId);
  }
}

export function hubStats() {
  return {
    sockets: wss ? wss.clients.size : 0,
    rooms: rooms.size,
    subscriptions: [...rooms.values()].reduce((n, s) => n + s.size, 0),
  };
}

export async function closeHub() {
  clearInterval(heartbeatTimer);
  clearInterval(coalesceTimer);
  if (!wss) return;
  for (const ws of wss.clients) ws.terminate();
  await new Promise((resolve) => wss.close(resolve));
  rooms.clear();
  roomIndex.clear();
  dirtyCounts.clear();
  wss = null;
}
