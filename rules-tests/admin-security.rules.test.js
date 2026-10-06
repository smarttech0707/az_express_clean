'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { collection, query, where, orderBy, limit, getDocs, getCountFromServer, doc, setDoc, updateDoc, deleteDoc } = require('firebase/firestore');
let env;
const since = new Date('2026-01-01');
const dbFor = (uid, provider = 'password') => env.authenticatedContext(uid, {
  firebase: { sign_in_provider: provider },
}).firestore();
function counts(db) {
  return [
    ...['payment_initiated', 'wallet_credited', 'withdrawal_initiated', 'order_auto_cancelled_no_driver'].map(action =>
      query(collection(db, 'audit_logs'), where('action', '==', action), where('createdAt', '>', since))),
    query(collection(db, 'security_events'), where('resolved', '==', false)),
    query(collection(db, 'security_events'), where('severity', '==', 'critical'), where('resolved', '==', false)),
    ...['webhook_invalid_secret', 'webhook_replay_attempt', 'order_rate_limit_exceeded'].map(event =>
      query(collection(db, 'security_events'), where('eventType', '==', event), where('createdAt', '>', since))),
  ];
}
function lists(db) {
  return [
    query(collection(db, 'audit_logs'), orderBy('createdAt', 'desc'), limit(15)),
    query(collection(db, 'security_events'), orderBy('createdAt', 'desc'), limit(10)),
    query(collection(db, 'dispatch_metrics'), orderBy('noDriverFoundCount', 'desc'), limit(5)),
  ];
}
test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-az-security',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
  await env.withSecurityRulesDisabled(async ctx => {
    const db = ctx.firestore();
    for (const [uid, data] of Object.entries({
      super: { role: 'super', isActive: true },
      sub: { role: 'sub', isActive: true, permissions: [] },
      inactive: { role: 'super', isActive: false },
      anonymous: { role: 'super', isActive: true },
    })) await setDoc(doc(db, 'admins', uid), data);
    for (const name of ['audit_logs', 'security_events', 'dispatch_metrics', 'rate_limits']) {
      await setDoc(doc(db, name, 'sample'), { createdAt: new Date(), updatedAt: new Date(),
        eventType: 'order_rate_limit_exceeded', action: 'payment_initiated',
        resolved: false, severity: 'critical', noDriverFoundCount: 3 });
    }
    for (const [name, uid] of [['clients', 'client'], ['livreurs', 'driver'], ['sellers', 'seller'], ['restaurants', 'partner']]) {
      await setDoc(doc(db, name, uid), { uid, isActive: true });
    }
  });
});
test.after(async () => { if (env) await env.cleanup(); });

test('super-admin: all Flutter aggregates and list queries are allowed', async () => {
  const db = dbFor('super');
  for (const q of counts(db)) await assertSucceeds(getCountFromServer(q));
  for (const q of lists(db)) await assertSucceeds(getDocs(q));
  const result = await getCountFromServer(counts(db).at(-1));
  assert.equal(result.data().count, 1);
});
for (const uid of ['sub', 'inactive', 'client', 'driver', 'seller', 'partner', 'anonymous', 'unauthenticated']) {
  test(`${uid}: security dashboard reads denied`, async () => {
    const db = uid === 'unauthenticated' ? env.unauthenticatedContext().firestore() : dbFor(uid, uid === 'anonymous' ? 'anonymous' : 'password');
    for (const q of counts(db)) await assertFails(getCountFromServer(q));
    for (const q of lists(db)) await assertFails(getDocs(q));
  });
}
test('original rate_limits aggregate remains denied even to super-admin', async () => {
  await assertFails(getCountFromServer(query(collection(dbFor('super'), 'rate_limits'), where('updatedAt', '>', since))));
});
test('client-side create/update/delete forbidden including super-admin', async () => {
  for (const uid of ['super', 'sub', 'client', 'driver', 'seller', 'partner']) {
    for (const name of ['audit_logs', 'security_events', 'rate_limits', 'dispatch_metrics']) {
      const db = dbFor(uid);
      await assertFails(setDoc(doc(db, name, 'new'), { action: 'forged' }));
      await assertFails(updateDoc(doc(db, name, 'sample'), { resolved: true }));
      await assertFails(deleteDoc(doc(db, name, 'sample')));
    }
  }
});
