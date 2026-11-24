'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { makeFakeDb, fakeAdmin } = require('./smsTestHelpers');
const { SmsProvider, MockSmsProvider, normalizeCiMobile, receiptSms, configuredSmsProvider } = require('../smsProvider');
const { buildDeliveryProofSms, smsRef } = require('../deliveryProofSms');
const { sessionId, PROOF_TTL_MS, verifyProofInTransaction } = require('../deliveryProofs');
const { buildDeliverOrderWithProof } = require('../orderActions');
const PEPPER = 'sms-test-only-pepper';
const req = (uid = 'c1', extra = {}) => ({ auth: { uid }, data: { orderId: 'o1', ...extra } });
const onCall = (_, handler) => handler;

async function fixture(run, { outcome = 'simulated', order = {}, provider } = {}) {
  const keys = ['DELIVERY_PROOFS_ENABLED', 'DELIVERY_SMS_ENABLED', 'DELIVERY_PROOF_PEPPER'];
  const previous = keys.map(key => process.env[key]);
  keys.forEach((key, i) => { process.env[key] = i === 2 ? PEPPER : 'true'; });
  let now = Date.now();
  const sent = [];
  const sms = provider || new MockSmsProvider({ outcome, inspect: message => sent.push(message) });
  const data = makeFakeDb({
    'orders/o1': { clientId: 'c1', driverId: 'd1', status: 'picked_up', deliveryProofMode: 'qr_v1',
      driverAssignmentVersion: 1, recipientName: 'Proche', recipientPhone: '0700000000',
      budget: 1000, paymentMethod: 'cash', isPaid: false, ...order },
    [`delivery_proofs/${sessionId('o1', 'pickup')}`]: { currentProofId: 'used' },
    [`delivery_proofs/${sessionId('o1', 'pickup')}/versions/used`]: { status: 'used' },
  });
  const deps = { db: data.db, admin: fakeAdmin, onCall, HttpsError, checkRateLimit: async () => {},
    providerFactory: () => sms, clock: () => now };
  const api = buildDeliveryProofSms(deps);
  const state = () => data.store.get(smsRef(data.db, 'o1').__path);
  const send = async () => { await api.configure(req()); await api.arrival(req('d1')); await api.dispatch('o1'); };
  try { await run({ ...data, deps, api, sms, sent, state, send, advance: () => { now += PROOF_TTL_MS + 1; } }); }
  finally { keys.forEach((key, i) => { if (previous[i] === undefined) delete process.env[key]; else process.env[key] = previous[i]; }); }
}

test('CI mobiles: local, international, spaces and all three prefixes', () => {
  for (const prefix of ['01', '05', '07']) {
    assert.equal(normalizeCiMobile(`${prefix} 00 00 00 00`), `+225${prefix}00000000`);
    assert.equal(normalizeCiMobile(`00225${prefix}00000000`), `+225${prefix}00000000`);
    assert.equal(normalizeCiMobile(`+225${prefix}00000000`), `+225${prefix}00000000`);
  }
});
test('invalid and legacy eight-digit phones refused, no guessed country', () => {
  for (const value of [null, '', '07000000', '+330700000000', '+2252700000000', 'a0700000000', '+225+0700000000']) {
    assert.throws(() => normalizeCiMobile(value));
  }
});
test('SMS is a single GSM-7 segment with handover warning', () => {
  const body = receiptSms('012345');
  assert(body.length <= 160);
  assert.match(body, /^[\x20-\x7e]+$/);
  assert(body.includes('012345') && body.includes('uniquement apres reception'));
});
test('provider defaults unavailable and cannot send real SMS', async () => {
  assert.equal(new SmsProvider().available, false);
  assert.equal(configuredSmsProvider().available, false);
  await assert.rejects(new SmsProvider().send({}));
});
test('self/historical orders emit nothing without explicit recipient choice', async () => fixture(async f => {
  await f.api.dispatch('o1');
  assert.equal(f.sms.calls, 0);
  assert.equal((await f.api.status(req())).status, 'not_configured');
}));
test('relative without app/WhatsApp gets simulated PIN; no PIN persisted or returned', async () => fixture(async f => {
  await f.send();
  assert.equal(f.sent.length, 1);
  const pin = f.sent[0].body.match(/\b\d{6}\b/)[0];
  assert.equal(f.sent[0].to, '+2250700000000');
  const stored = JSON.stringify([...f.store]);
  assert(!stored.includes(pin) && !stored.includes(f.sent[0].body));
  const result = await f.api.status(req());
  assert.equal(result.status, 'simulated');
  assert(!JSON.stringify(result).includes(pin));
  assert(!Object.hasOwn(result, 'phone'));
}));
test('only client can opt in/resend/read; driver cannot supply a phone', async () => fixture(async f => {
  for (const method of ['configure', 'retry', 'status']) await assert.rejects(f.api[method](req('d1')));
  await assert.rejects(f.api.configure(req('other')));
  await assert.rejects(f.api.configure({ data: { orderId: 'o1' } }));
  await assert.rejects(f.api.arrival(req('d1', { phone: '+2250500000000' })));
  await f.api.configure(req());
  await assert.rejects(f.api.arrival(req('other')));
}));
test('missing recipient / invalid phone / historical / wrong step rejected', async () => {
  for (const order of [{ recipientName: '' }, { recipientPhone: 'bad' }, { deliveryProofMode: null }, { status: 'accepted' }]) {
    await fixture(async f => { await assert.rejects(f.api.configure(req())); assert.equal(f.sms.calls, 0); }, { order });
  }
});
test('waiting until arrival; repeated/concurrent events only send once', async () => fixture(async f => {
  await f.api.configure(req());
  await f.api.dispatch('o1');
  assert.equal(f.sms.calls, 0);
  await Promise.all([f.api.arrival(req('d1')), f.api.arrival(req('d1'))]);
  await Promise.all([f.api.dispatch('o1'), f.api.dispatch('o1')]);
  await f.api.arrival(req('d1'));
  await f.api.dispatch('o1');
  assert.equal(f.sms.calls, 1);
}));
test('provider refusal recorded without provider details', async () => fixture(async f => {
  await f.send(); assert.equal(f.state().status, 'failed');
}, { outcome: 'failed' }));
test('provider unavailable does not issue a proof or consume budgets', async () => fixture(async f => {
  await f.send(); assert.equal(f.state().status, 'unavailable');
  assert.equal(f.state().attempts, 0);
  assert(![...f.store.keys()].some(k => k.includes('sms_budget_')));
}, { provider: new SmsProvider() }));
test('timeout is unknown, replay cannot double-send; retry only after expiration', async () => fixture(async f => {
  await f.send(); assert.equal(f.state().status, 'unknown');
  await f.api.dispatch('o1'); assert.equal(f.sms.calls, 1);
  await assert.rejects(f.api.retry(req()));
  f.advance(); await f.api.retry(req()); await f.api.dispatch('o1');
  assert.equal(f.sms.calls, 2);
}, { outcome: 'unknown' }));
test('resends bounded by shared three-proof generation limit', async () => fixture(async f => {
  await f.send();
  for (let i = 0; i < 2; i++) { f.advance(); await f.api.retry(req()); await f.api.dispatch('o1'); }
  f.advance(); await assert.rejects(f.api.retry(req())); assert.equal(f.sms.calls, 3);
}));
test('phone changes and reassignment fail closed before sending', async () => {
  for (const change of [{ recipientPhone: '0500000000' }, { driverId: 'd2' }, { driverAssignmentVersion: 2 }, { status: 'cancelled' }]) {
    await fixture(async f => {
      await f.api.configure(req()); await f.api.arrival(req('d1'));
      f.store.set('orders/o1', { ...f.store.get('orders/o1'), ...change });
      await f.api.dispatch('o1'); assert.equal(f.sms.calls, 0); assert.equal(f.state().status, 'blocked');
    });
  }
});
test('daily global budget blocks charges before contacting provider', async () => fixture(async f => {
  const day = new Date().toISOString().slice(0, 10);
  f.store.set(`delivery_proofs/sms_budget_${day}_global`, { count: 100 });
  await f.send(); assert.equal(f.sms.calls, 0); assert.equal(f.state().status, 'limited');
}));
test('expired and incorrect PIN rejected by existing verifier', async () => fixture(async f => {
  await f.send();
  const pin = f.sent[0].body.match(/\b\d{6}\b/)[0];
  async function verify(value, now) {
    return f.db.runTransaction(tx => verifyProofInTransaction({ tx, db: f.db, orderId: 'o1', type: 'delivery',
      driverId: 'd1', assignmentVersion: 1, pin: value, pepper: PEPPER, now, admin: fakeAdmin }));
  }
  assert.equal((await verify(pin, Date.now())).ok, true);
  assert.equal((await verify(pin === '000000' ? '111111' : '000000', Date.now())).ok, false);
  assert.equal((await verify(pin, f.state().expiresAt + 1)).ok, false);
}));
test('existing delivery callable consumes SMS PIN once; no double settlement', async () => fixture(async f => {
  await f.send(); const pin = f.sent[0].body.match(/\b\d{6}\b/)[0];
  const deliver = buildDeliverOrderWithProof({ ...f.deps, logAudit: async () => {} });
  await deliver(req('d1', { proofPin: pin, markCashPaid: true }));
  const snapshot = JSON.stringify([...f.store]);
  await assert.rejects(deliver(req('d1', { proofPin: pin, markCashPaid: true })));
  assert.equal(JSON.stringify([...f.store]), snapshot);
  assert.equal(f.store.get('orders/o1').status, 'delivered');
}));
test('feature is off unless both server gates enabled', async () => fixture(async f => {
  process.env.DELIVERY_SMS_ENABLED = 'false';
  await assert.rejects(f.api.configure(req()));
  await assert.rejects(f.api.dispatch('o1'));
  assert.equal(f.sms.calls, 0);
}));

test('accepted is not delivered; expiry shown without claiming receipt', async () => fixture(async f => {
  await f.send(); assert.equal((await f.api.status(req())).status, 'accepted');
  f.advance();
  const state = await f.api.status(req());
  assert.equal(state.status, 'expired'); assert.equal(state.canRetry, true);
}, { outcome: 'accepted' }));

test('unavailable provider can be retried safely after recovery', async () => fixture(async f => {
  let ready = false;
  const adapter = { get available() { return ready; }, send: message => f.sms.send(message) };
  const api = buildDeliveryProofSms({ ...f.deps, providerFactory: () => adapter });
  await api.configure(req()); await api.arrival(req('d1')); await api.dispatch('o1');
  assert.equal(f.state().status, 'unavailable');
  await assert.rejects(api.retry(req()));
  ready = true; f.advance(); await api.retry(req()); await api.dispatch('o1');
  assert.equal(f.sms.calls, 1);
}));

test('crash after reservation does not replay the provider send', async () => fixture(async f => {
  await f.api.configure(req()); await f.api.arrival(req('d1'));
  const original = f.db.runTransaction;
  let calls = 0;
  f.db.runTransaction = callback => {
    calls++;
    if (calls === 2) return Promise.reject(new Error('simulated result write failure'));
    return original(callback);
  };
  await assert.rejects(f.api.dispatch('o1'));
  f.db.runTransaction = original;
  assert.equal(f.state().status, 'sending');
  await f.api.dispatch('o1');
  assert.equal(f.sms.calls, 1);
}));

test('new QR/guest proof supersedes SMS and cannot be overwritten by SMS retry', async () => fixture(async f => {
  await f.send(); f.advance();
  const path = `delivery_proofs/${sessionId('o1', 'delivery')}`;
  f.store.set(path, { ...f.store.get(path), currentProofId: 'another-proof' });
  assert.equal((await f.api.status(req())).status, 'superseded');
  await assert.rejects(f.api.retry(req()));
}));
