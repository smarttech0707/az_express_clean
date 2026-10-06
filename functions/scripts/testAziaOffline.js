'use strict';
// Local unit tests only, never test-emulator. Optional filenames select a suite.
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const guard = path.join(root, 'test/support/offlineGuard.cjs');
const requested = process.argv.slice(2);
const files = requested.length ? requested : fs.readdirSync(path.join(root, 'test')).filter(f => f.endsWith('.test.js')).sort();
let failures = 0, passed = 0, failed = 0, cancelled = 0;
for (const file of files) {
  if (path.basename(file) !== file || !file.endsWith('.test.js')) throw new Error('Expected a unit-test filename');
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (/API_KEY|FEEXPAY|GOOGLE_APPLICATION_CREDENTIALS|NODE_OPTIONS|^AI_|_MODEL$/.test(key)) delete env[key];
  }
  env.NODE_OPTIONS = `--require="${guard.replace(/\\/g, '/')}"`;
  env.GCLOUD_PROJECT = 'demo-azia-offline';
  const result = spawnSync(process.execPath, ['--test', '--test-reporter=tap', path.join(root, 'test', file)], {
    cwd: root, env, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024,
  });
  const output = (result.stdout || '') + '\n' + (result.stderr || '');
  const number = label => Number(output.match(new RegExp(`^# ${label} (\\d+)$`, 'm'))?.[1] || 0);
  const summary = { file, exit: result.status, timeout: result.error?.code === 'ETIMEDOUT',
    passed: number('pass'), failed: number('fail'), cancelled: number('cancelled') };
  console.log(JSON.stringify(summary));
  passed += summary.passed; failed += summary.failed; cancelled += summary.cancelled;
  if (result.status !== 0 || result.error || summary.cancelled || summary.failed || !summary.passed) {
    failures++; console.error(output);
  }
}
console.log(JSON.stringify({ suites: files.length, failedSuites: failures, passed, failed, cancelled }));
process.exitCode = failures ? 1 : 0;
