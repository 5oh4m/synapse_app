// Password hashing, JWT minting, refresh-token rotation.
//
// Defect fixed: the previous server stored the plaintext password in a Map and
// mirrored it into data.json. Nothing here ever holds plaintext beyond the
// bcrypt call, and password_hash is never selected into a response.
import crypto from 'node:crypto';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { config } from '../config.js';
import { pool, one, withTransaction, UNIQUE_VIOLATION } from '../db/pool.js';
import { conflict, unauthorized, notFound } from '../errors.js';
import { userJson } from '../util/serialize.js';

export const hashPassword = (plain) => bcrypt.hash(plain, config.bcryptCost);
export const verifyPassword = (plain, hash) => bcrypt.compare(plain, hash);

const sha256 = (v) => crypto.createHash('sha256').update(v).digest('hex');

export function signAccessToken(user) {
  return jwt.sign(
    { sub: user.id, role: user.role, email: user.email, name: user.name },
    config.jwtSecret,
    { algorithm: 'HS256', expiresIn: config.accessTtlSeconds },
  );
}

export function verifyAccessToken(token) {
  return jwt.verify(token, config.jwtSecret, { algorithms: ['HS256'] });
}

/** Opaque 256-bit refresh token; only its SHA-256 is stored. */
async function issueRefreshToken(client, userId) {
  const token = crypto.randomBytes(32).toString('base64url');
  const expires = new Date(Date.now() + config.refreshTtlDays * 86_400_000);
  await client.query(
    'INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)',
    [userId, sha256(token), expires],
  );
  return token;
}

export async function register({ name, email, password, role }) {
  const password_hash = await hashPassword(password);
  try {
    return await withTransaction(async (client) => {
      const { rows } = await client.query(
        `INSERT INTO users (name, email, password_hash, role)
         VALUES ($1, $2, $3, $4)
         RETURNING id, name, email, role, created_at`,
        [name, email, password_hash, role],
      );
      const user = rows[0];
      const refreshToken = await issueRefreshToken(client, user.id);
      return { user: userJson(user), accessToken: signAccessToken(user), refreshToken };
    });
  } catch (err) {
    if (err.code === UNIQUE_VIOLATION) {
      throw conflict('An account with that email already exists.', 'email');
    }
    throw err;
  }
}

export async function login({ email, password }) {
  const row = await one(
    'SELECT id, name, email, role, password_hash, created_at FROM users WHERE email = $1',
    [email],
  );
  // Same message and (roughly) the same work either way, so the response does
  // not reveal whether the address exists.
  if (!row) {
    await bcrypt.compare(password, '$2b$12$ttttttttttttttttttttttttttttttttttttttttttttttttttttt');
    throw unauthorized('Wrong email or password.');
  }
  if (!(await verifyPassword(password, row.password_hash))) {
    throw unauthorized('Wrong email or password.');
  }
  const refreshToken = await withTransaction((client) => issueRefreshToken(client, row.id));
  return { user: userJson(row), accessToken: signAccessToken(row), refreshToken };
}

/** Rotates: the presented token is revoked and a fresh one returned. */
export async function refresh(presented) {
  if (typeof presented !== 'string' || presented.length < 20) {
    throw unauthorized('That refresh token is not valid.');
  }
  return withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT rt.id, rt.user_id, rt.expires_at, rt.revoked_at,
              u.id AS uid, u.name, u.email, u.role, u.created_at
         FROM refresh_tokens rt
         JOIN users u ON u.id = rt.user_id
        WHERE rt.token_hash = $1
        FOR UPDATE OF rt`,
      [sha256(presented)],
    );
    const row = rows[0];
    if (!row) throw unauthorized('That refresh token is not valid.');
    if (row.revoked_at) throw unauthorized('That refresh token has already been used.');
    if (new Date(row.expires_at) <= new Date()) throw unauthorized('Your session expired.');

    await client.query('UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1', [row.id]);
    const user = {
      id: row.uid,
      name: row.name,
      email: row.email,
      role: row.role,
      created_at: row.created_at,
    };
    const refreshToken = await issueRefreshToken(client, user.id);
    return { accessToken: signAccessToken(user), refreshToken, user: userJson(user) };
  });
}

export async function revokeRefreshToken(presented, userId) {
  if (typeof presented !== 'string' || !presented) return;
  await pool.query(
    `UPDATE refresh_tokens SET revoked_at = now()
      WHERE token_hash = $1 AND user_id = $2 AND revoked_at IS NULL`,
    [sha256(presented), userId],
  );
}

export async function getUser(id) {
  const row = await one('SELECT id, name, email, role, created_at FROM users WHERE id = $1', [id]);
  if (!row) throw notFound('That account no longer exists.');
  return userJson(row);
}

export async function updateProfile(id, { name }) {
  const row = await one(
    `UPDATE users SET name = COALESCE($2, name) WHERE id = $1
     RETURNING id, name, email, role, created_at`,
    [id, name ?? null],
  );
  if (!row) throw notFound('That account no longer exists.');
  return userJson(row);
}
