'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

assert.match(process.env.FIRESTORE_EMULATOR_HOST || '', /^(127\.0\.0\.1|localhost):\d+$/);

test('a timed-out writer cannot reuse or corrupt the next Firestore fixture', { timeout: 30000 }, () => {
  const helper = require.resolve('./support/isolatedFirestoreTest');
  const source = `
    const assert = require('node:assert/strict');
    const { test, db, fixture } = require(${JSON.stringify(helper)}).createIsolatedFirestoreTest('demo-timeout');
    let active = false, firstProject, release, done;
    const completed = new Promise(resolve => { done = resolve; });
    test('intentional timeout', { timeout: 3000 }, async () => {
      firstProject = fixture().projectId;
      await db.doc('fixtures/shared').set({ owner: 'first' });
      active = true;
      await new Promise(resolve => { release = resolve; });
      try {
        // Resolve db AFTER the next test has started: async context must still
        // route this delayed writer to the first test's database.
        assert.equal(fixture().projectId, firstProject);
        await db.doc('fixtures/shared').set({ owner: 'late-first' });
      } finally { active = false; done(); }
    });
    test('next fixture remains isolated', { timeout: 10000 }, async () => {
      console.log('NEXT_TEST_WHILE_WRITER_ACTIVE=' + active);
      assert.equal(active, true);
      assert.notEqual(fixture().projectId, firstProject);
      await db.doc('fixtures/shared').set({ owner: 'second' });
      release();
      await completed;
      assert.equal((await db.doc('fixtures/shared').get()).data().owner, 'second');
      console.log('FIXTURES_REUSED=false');
      console.log('NEXT_FIXTURE_INTACT=true');
    });
  `;
  const childEnv = { ...process.env };
  delete childEnv.NODE_TEST_CONTEXT;
  const result = spawnSync(process.execPath, ['--test-reporter=tap', '-e', source], {
    env: childEnv, encoding: 'utf8', timeout: 20000,
  });
  // The child MUST fail: its deliberately timed-out test is never reclassified
  // as successful. The parent verifies that failure and the isolation evidence.
  console.log(JSON.stringify({ probe: 'intentional-timeout', exit: result.status,
    externalTimeout: result.error?.code === 'ETIMEDOUT' }));
  console.log(result.stdout);
  if (result.stderr) console.error(result.stderr);
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /NEXT_TEST_WHILE_WRITER_ACTIVE=true/);
  assert.match(result.stdout, /FIXTURES_REUSED=false/);
  assert.match(result.stdout, /NEXT_FIXTURE_INTACT=true/);
  assert.match(result.stdout, /cancelled 1/);
  assert.match(result.stdout, /pass 1/);
});
