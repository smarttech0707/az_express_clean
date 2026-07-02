'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { hashSecret, verifySecret } = require('../passwordHash');

test('hashSecret never stores the plaintext password', () => {
  const stored = hashSecret('pharma123');
  assert.ok(!stored.includes('pharma123'));
  assert.match(stored, /^[0-9a-f]+:[0-9a-f]+$/);
});

test('hashSecret produces a different salt (and hash) every call', () => {
  const a = hashSecret('same-password');
  const b = hashSecret('same-password');
  assert.notEqual(a, b);
});

test('verifySecret accepts the correct password', () => {
  const stored = hashSecret('correct horse battery staple');
  assert.equal(verifySecret('correct horse battery staple', stored), true);
});

test('verifySecret rejects a wrong password', () => {
  const stored = hashSecret('correct horse battery staple');
  assert.equal(verifySecret('wrong password', stored), false);
});

test('verifySecret rejects malformed/missing stored values without throwing', () => {
  assert.equal(verifySecret('anything', null), false);
  assert.equal(verifySecret('anything', undefined), false);
  assert.equal(verifySecret('anything', ''), false);
  assert.equal(verifySecret('anything', 'no-colon-here'), false);
  assert.equal(verifySecret('anything', 'bad:salt:format'), false);
});

test('verifySecret is not fooled by a truncated/tampered hash', () => {
  const stored = hashSecret('pharma123');
  const [salt, hash] = stored.split(':');
  const tampered = `${salt}:${hash.slice(0, -2)}00`;
  assert.equal(verifySecret('pharma123', tampered), false);
});
