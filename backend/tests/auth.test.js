import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import { api, resetDb, shutdown, makeUser, uniqueEmail, query, errorCode } from './helpers.js';

before(resetDb);
beforeEach(resetDb);
after(shutdown);

describe('auth', () => {
  test('register returns 201 with tokens and a user, and never a hash', async () => {
    const email = uniqueEmail('educator');
    const res = await api()
      .post('/api/auth/register')
      .send({ name: 'Ada Lovelace', email, password: 'correct-horse-1', role: 'educator' });

    assert.equal(res.status, 201);
    assert.ok(res.body.accessToken, 'accessToken missing');
    assert.ok(res.body.refreshToken, 'refreshToken missing');
    assert.equal(res.body.user.email, email);
    assert.equal(res.body.user.role, 'educator');
    assert.equal(res.body.user.password_hash, undefined);
    assert.equal(res.body.user.password, undefined);
    assert.ok(!JSON.stringify(res.body).includes('correct-horse-1'), 'password echoed back');
  });

  test('the password is bcrypt-hashed at rest, never stored in plaintext', async () => {
    const password = 'a-very-secret-1';
    const u = await makeUser({ role: 'student', password });
    const { rows } = await query('SELECT password_hash FROM users WHERE id = $1', [u.id]);
    const hash = rows[0].password_hash;
    assert.match(hash, /^\$2[aby]\$\d{2}\$/, 'not a bcrypt hash');
    assert.notEqual(hash, password);
    assert.ok(!hash.includes(password));
  });

  test('login happy path', async () => {
    const u = await makeUser({ role: 'student', password: 'login-me-please-1' });
    const res = await api()
      .post('/api/auth/login')
      .send({ email: u.email, password: 'login-me-please-1' });
    assert.equal(res.status, 200);
    assert.ok(res.body.accessToken);
    assert.equal(res.body.user.id, u.id);
  });

  test('login with the wrong password is 401 and does not say which field was wrong', async () => {
    const u = await makeUser({ role: 'student', password: 'right-password-1' });
    const res = await api()
      .post('/api/auth/login')
      .send({ email: u.email, password: 'wrong-password-1' });
    assert.equal(res.status, 401);
    assert.equal(errorCode(res), 'UNAUTHORIZED');
    assert.match(res.body.error.message, /wrong email or password/i);
    assert.equal(res.body.accessToken, undefined);
  });

  test('login for an unknown address gives the same 401', async () => {
    const res = await api()
      .post('/api/auth/login')
      .send({ email: uniqueEmail('nobody'), password: 'whatever-1234' });
    assert.equal(res.status, 401);
    assert.match(res.body.error.message, /wrong email or password/i);
  });

  test('duplicate email is 409 on the email field', async () => {
    const email = uniqueEmail('dupe');
    const first = await api()
      .post('/api/auth/register')
      .send({ name: 'First', email, password: 'password-one-1', role: 'student' });
    assert.equal(first.status, 201);

    const second = await api()
      .post('/api/auth/register')
      .send({ name: 'Second', email: email.toUpperCase(), password: 'password-two-1', role: 'student' });
    assert.equal(second.status, 409);
    assert.equal(errorCode(second), 'CONFLICT');
    assert.equal(second.body.error.field, 'email');
  });

  test('a short password is rejected with a field-level 422', async () => {
    const res = await api()
      .post('/api/auth/register')
      .send({ name: 'Shorty', email: uniqueEmail('short'), password: 'short', role: 'student' });
    assert.equal(res.status, 422);
    assert.equal(res.body.error.field, 'password');
  });

  test('an unknown role is rejected', async () => {
    const res = await api()
      .post('/api/auth/register')
      .send({ name: 'Admin', email: uniqueEmail('admin'), password: 'password-1234', role: 'admin' });
    assert.equal(res.status, 422);
    assert.equal(res.body.error.field, 'role');
  });

  test('refresh rotates: the new token works and the old one is dead', async () => {
    const u = await makeUser({ role: 'student' });

    const first = await api().post('/api/auth/refresh').send({ refreshToken: u.refreshToken });
    assert.equal(first.status, 200);
    assert.ok(first.body.accessToken);
    assert.notEqual(first.body.refreshToken, u.refreshToken, 'refresh token was not rotated');

    const replay = await api().post('/api/auth/refresh').send({ refreshToken: u.refreshToken });
    assert.equal(replay.status, 401, 'a used refresh token must not work twice');

    const second = await api()
      .post('/api/auth/refresh')
      .send({ refreshToken: first.body.refreshToken });
    assert.equal(second.status, 200);
  });

  test('the access token from refresh authenticates /auth/me', async () => {
    const u = await makeUser({ role: 'educator' });
    const r = await api().post('/api/auth/refresh').send({ refreshToken: u.refreshToken });
    const me = await api().get('/api/auth/me').set('authorization', `Bearer ${r.body.accessToken}`);
    assert.equal(me.status, 200);
    assert.equal(me.body.user.id, u.id);
  });

  test('logout revokes that refresh token', async () => {
    const u = await makeUser({ role: 'student' });
    const out = await u.post('/api/auth/logout').send({ refreshToken: u.refreshToken });
    assert.equal(out.status, 204);

    const after = await api().post('/api/auth/refresh').send({ refreshToken: u.refreshToken });
    assert.equal(after.status, 401);
  });

  test('GET /auth/me needs a bearer token', async () => {
    const anon = await api().get('/api/auth/me');
    assert.equal(anon.status, 401);
    assert.equal(errorCode(anon), 'UNAUTHORIZED');

    const garbage = await api().get('/api/auth/me').set('authorization', 'Bearer not.a.jwt');
    assert.equal(garbage.status, 401);
  });

  test('PATCH /auth/me updates the name only', async () => {
    const u = await makeUser({ role: 'student', name: 'Old Name' });
    const res = await u.patch('/api/auth/me').send({ name: 'New Name' });
    assert.equal(res.status, 200);
    assert.equal(res.body.user.name, 'New Name');
    assert.equal(res.body.user.email, u.email);
  });

  test('a body that supplies an identity field is refused', async () => {
    const u = await makeUser({ role: 'student' });
    const res = await u.patch('/api/auth/me').send({ name: 'X', user_id: u.id });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.field, 'user_id');
  });
});
