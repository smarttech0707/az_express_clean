'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('Storage exige explicitement un Admin réel, actif et de rôle reconnu', () => {
  const rules = fs.readFileSync(path.join(__dirname, '..', '..', 'storage.rules'), 'utf8');
  assert.match(rules, /isRealUser\(\)/);
  assert.match(rules, /doc\.isActive == true/);
  assert.match(rules, /doc\.role in \['super', 'sub'\]/);
  assert.doesNotMatch(rules, /function isAdmin\(\)[\s\S]*?return isAuth\(\)\s*&&\s*firestore\.exists/);
});
