// Rate limits at their production values. .env.test raises every limit so the
// other suites can register freely; this file pins the shipped defaults before
// the app is imported (dotenv never overrides a variable that is already set).
process.env.RATE_LIMIT_AUTH = '10';
process.env.RATE_LIMIT_AUTH_IP = '300';
process.env.RATE_LIMIT_GLOBAL = '60';
process.env.TRUST_PROXY_HOPS = '0';

import test, { before, after, describe } from 'node:test';
import assert from 'node:assert/strict';

const h = await import('./helpers.js');

before(h.resetDb);
after(h.shutdown);

const register = (email, headers = {}) =>
  h
    .api()
    .post('/api/auth/register')
    .set(headers)
    .send({ name: 'Student', email, password: 'classroom-pass-1', role: 'student' });

const login = (email, password, headers = {}) =>
  h.api().post('/api/auth/login').set(headers).send({ email, password });

describe('rate limits in a classroom that shares one IP', () => {
  test('a whole class can register from one address', async () => {
    const statuses = [];
    for (let i = 0; i < 20; i += 1) {
      statuses.push((await register(h.uniqueEmail('class'))).status);
    }
    assert.ok(statuses.every((s) => s === 201), `class sign-up was throttled: ${statuses.join(' ')}`);
  });

  test('guessing one account is still limited to 10 per 15 minutes', async () => {
    const email = h.uniqueEmail('target');
    await register(email);
    const statuses = [];
    for (let i = 0; i < 11; i += 1) statuses.push((await login(email, 'wrong-password-1')).status);
    assert.deepEqual(statuses.slice(0, 10), Array(10).fill(401));
    assert.equal(statuses[10], 429);

    // A classmate on the same network is unaffected.
    const other = h.uniqueEmail('classmate');
    await register(other);
    assert.equal((await login(other, 'classroom-pass-1')).status, 200);
  });

  test('a forged X-Forwarded-For does not buy a fresh allowance', async () => {
    const email = h.uniqueEmail('forger');
    await register(email);
    for (let i = 0; i < 10; i += 1) await login(email, 'wrong-password-1');
    const forged = await login(email, 'wrong-password-1', { 'X-Forwarded-For': '203.0.113.77' });
    assert.equal(forged.status, 429, 'X-Forwarded-For was trusted with no proxy in front');
  });

  test('signed-in students each get their own global allowance', async () => {
    const a = await h.makeUser({ role: 'student' });
    const b = await h.makeUser({ role: 'student' });
    let first429 = null;
    for (let i = 1; i <= 61; i += 1) {
      const res = await a.get('/api/auth/me');
      if (res.status === 429) {
        first429 = i;
        break;
      }
    }
    assert.equal(first429, 61);
    assert.equal((await b.get('/api/auth/me')).status, 200, 'a classmate shared the exhausted bucket');
  });
});
