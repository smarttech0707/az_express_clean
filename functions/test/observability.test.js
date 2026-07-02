'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { withObservability } = require('../observability');

function makeFakeDb() {
  const added = [];
  return {
    added,
    collection: (name) => ({
      add: async (data) => { added.push({ collection: name, data }); return { id: `auto${added.length}` }; },
    }),
  };
}

const fakeAdmin = {
  firestore: { FieldValue: { serverTimestamp: () => '__SERVER_TIMESTAMP__' } },
};

test('withObservability: logs a success entry and attaches requestId to the response', async () => {
  const db = makeFakeDb();
  const handler = async (request) => ({ value: request.data.x * 2 });
  const wrapped = withObservability({ db, admin: fakeAdmin }, 'doubleIt', handler);

  const result = await wrapped({ auth: { uid: 'u1' }, data: { x: 21 } });

  assert.equal(result.value, 42);
  assert.equal(typeof result.requestId, 'string');
  assert.ok(result.requestId.length > 0);

  assert.equal(db.added.length, 1);
  const entry = db.added[0];
  assert.equal(entry.collection, 'request_logs');
  assert.equal(entry.data.functionName, 'doubleIt');
  assert.equal(entry.data.userId, 'u1');
  assert.equal(entry.data.status, 'success');
  assert.equal(entry.data.requestId, result.requestId);
  assert.equal(typeof entry.data.durationMs, 'number');
});

test('withObservability: logs an error entry and still rethrows the original error', async () => {
  const db = makeFakeDb();
  const boom = new Error('kaboom');
  boom.code = 'failed-precondition';
  const handler = async () => { throw boom; };
  const wrapped = withObservability({ db, admin: fakeAdmin }, 'explodingFn', handler);

  await assert.rejects(
    () => wrapped({ auth: { uid: 'u1' }, data: {} }),
    (err) => err === boom,
  );

  assert.equal(db.added.length, 1);
  const entry = db.added[0];
  assert.equal(entry.data.status, 'error');
  assert.equal(entry.data.errorCode, 'failed-precondition');
  assert.equal(entry.data.errorMessage, 'kaboom');
});

test('withObservability: records a null userId for unauthenticated calls', async () => {
  const db = makeFakeDb();
  const handler = async () => ({ ok: true });
  const wrapped = withObservability({ db, admin: fakeAdmin }, 'publicFn', handler);

  await wrapped({ data: {} });

  assert.equal(db.added[0].data.userId, null);
});

test('withObservability: passes through a non-object result unchanged (no requestId injection)', async () => {
  const db = makeFakeDb();
  const handler = async () => 'plain-string-result';
  const wrapped = withObservability({ db, admin: fakeAdmin }, 'stringFn', handler);

  const result = await wrapped({ data: {} });

  assert.equal(result, 'plain-string-result');
});

test('withObservability: a request_logs write failure does not affect the caller-visible result', async () => {
  const db = {
    collection: () => ({ add: async () => { throw new Error('firestore down'); } }),
  };
  const handler = async () => ({ ok: true });
  const wrapped = withObservability({ db, admin: fakeAdmin }, 'resilientFn', handler);

  const result = await wrapped({ data: {} });
  assert.equal(result.ok, true);
});
