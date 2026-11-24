'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

test('le manifeste Cloud Functions charge sans ReferenceError', () => {
  const functionsDir = path.join(__dirname, '..');
  const result = spawnSync(
    process.execPath,
    ['-e', "const f=require('./index'); if(!f.walletReconciliationCheck || !f.aiCleanupExpiredPendingActions) process.exit(2);"],
    {
      cwd: functionsDir,
      encoding: 'utf8',
      timeout: 15000,
      env: { ...process.env, GCLOUD_PROJECT: 'az-express-b0469' },
    },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
});
