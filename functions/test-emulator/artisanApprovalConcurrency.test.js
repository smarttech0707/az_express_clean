'use strict';

const { createIsolatedFirestoreTest } = require('./support/isolatedFirestoreTest');
const assert = require('node:assert/strict');
const { randomInt } = require('node:crypto');
const admin = require('firebase-admin');
const { buildSetArtisanPin } = require('../artisanAccounts');
const { verifySecret } = require('../passwordHash');

const host = process.env.FIRESTORE_EMULATOR_HOST || '';
assert.match(host, /^(127\.0\.0\.1|localhost):\d+$/, 'Local emulator required');
const mode = process.env.ARTISAN_READ_DIAGNOSTIC || 'grouped';
assert.ok(['grouped', 'sequential'].includes(mode));
const delayMs = Number(process.env.ARTISAN_READ_DELAY_MS || 0);
assert.ok([0, 4000].includes(delayMs), 'Only bounded diagnostic delays are allowed');
const { test, db } = createIsolatedFirestoreTest('demo-lot75');
const fieldValue = admin.firestore.FieldValue;

test(`simultaneous approvals preserve atomicity (${mode})`, { timeout: 35000 }, async () => {
  await db.doc('admins/admin').set({ role: 'super', isActive: true });
  await db.doc('service_providers/provider').set({ status: 'pending' });
  const first = String(randomInt(100000, 1000000));
  let second;
  do { second = String(randomInt(100000, 1000000)); } while (second === first);
  const trace = [];
  function database(label) {
    let attempt = 0;
    const shouldDelay = process.env.ARTISAN_DELAY_ONE !== '1' || label === 'A';
    return {
      collection: name => db.collection(name),
      runTransaction: callback => db.runTransaction(async tx => {
        const current = ++attempt;
        const observed = new Proxy(tx, { get(target, key) {
          if (key === 'getAll') return async (...refs) => {
            let stage = 'grouped-read';
            try {
              let result;
              if (mode === 'sequential') {
                result = [];
                for (let i = 0; i < refs.length; i++) {
                  stage = `read-${i + 1}`;
                  result.push(await tx.get(refs[i]));
                  trace.push({ label, attempt: current, stage, outcome: 'ok' });
                  if (i === 0 && current === 1 && delayMs && shouldDelay) await new Promise(resolve => setTimeout(resolve, delayMs));
                }
              } else {
                result = await tx.getAll(...refs);
                trace.push({ label, attempt: current, stage, outcome: 'ok' });
                if (current === 1 && delayMs && shouldDelay) await new Promise(resolve => setTimeout(resolve, delayMs));
              }
              return result;
            } catch (error) {
              trace.push({ label, attempt: current, stage, code: error.code,
                closedTransaction: /Transaction is invalid or closed/.test(error.message) });
              throw error;
            }
          };
          const value = Reflect.get(target, key);
          return typeof value === 'function' ? value.bind(target) : value;
        } });
        return callback(observed);
      }),
    };
  }
  const request = pin => ({ auth: { uid: 'admin', token: { firebase: { sign_in_provider: 'password' } } },
    data: { providerId: 'provider', pin, approve: true } });
  const results = await Promise.allSettled([
    buildSetArtisanPin({ db: database('A'), fieldValue })(request(first)),
    buildSetArtisanPin({ db: database('B'), fieldValue })(request(second)),
  ]);
  // No rejected operation can leave its sibling running into the next fixture.
  // Trace never includes PINs, hashes, document contents or SDK request dumps.
  console.log(JSON.stringify({ mode, delayMs, trace, outcomes: results.map(r => r.status === 'fulfilled'
    ? { status: r.status, alreadyApproved: r.value.alreadyApproved, pinSet: r.value.pinSet }
    : { status: r.status, code: r.reason.code,
      closedTransaction: /Transaction is invalid or closed/.test(r.reason.message) }) }));
  const [provider, credential, audits] = await Promise.all([
    db.doc('service_providers/provider').get(), db.doc('artisan_credentials/provider').get(),
    db.collection('audit_logs').get(),
  ]);
  assert.equal(provider.data().status, 'approved');
  assert.equal(Object.hasOwn(provider.data(), 'artisanPin'), false);
  assert.equal(audits.size, 1, 'Exactly one approval commit');
  const matches = [first, second].map(pin => verifySecret(pin, credential.data().hash));
  assert.equal(matches.filter(Boolean).length, 1);
  assert.equal(results.filter(r => r.status === 'rejected').length, 0, 'Every caller must finish without a transport error');
  assert.equal(results.filter(r => r.value.pinSet).length, 1);
  assert.equal(results.filter(r => r.value.alreadyApproved).length, 1);
});
