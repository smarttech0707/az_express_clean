'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { settleConcurrent } = require('../test-emulator/support/settleConcurrent');

test('concurrent test harness drains pending writers and preserves all errors', async () => {
  const first = new Error('first fixture failure');
  const second = new Error('second fixture failure');
  let release, finished = false;
  const pendingWriter = new Promise((resolve, reject) => { release = () => reject(second); });
  const operation = settleConcurrent([Promise.reject(first), pendingWriter]);
  const observation = operation.then(() => { finished = true; }, () => { finished = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(finished, false, 'Fixture cleanup must wait for the second writer');
  release();
  await assert.rejects(operation, error => error instanceof AggregateError
    && error.errors.length === 2 && error.errors[0] === first && error.errors[1] === second);
  await observation;
});

test('concurrent test harness returns real results in call order without retry', async () => {
  let calls = 0;
  const operation = async value => { calls++; return value; };
  assert.deepEqual(await settleConcurrent([operation('first'), operation('second')]), ['first', 'second']);
  assert.equal(calls, 2);
});
