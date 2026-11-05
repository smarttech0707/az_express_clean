'use strict';

// Mission 7E-26 — nettoyage des offres (pendingOrderId) APRÈS une acceptation validée, dans acceptOrderCF.
// Le déclencheur syncDriverOrderLifecycle (sans réessai en préproduction) reste le filet de secours ; ces tests fixent le contrat :
// le nettoyage ne change jamais l'issue de l'acceptation, ni les montants, ni l'état d'un livreur occupé ailleurs.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildAcceptOrder } = require('../driverAcceptance');
const { clearAcceptedOffers } = require('../driverLifecycle');
const { calculateCommission } = require('../dispatch');
const { fakeDb, DELETE } = require('./fakeFirestore');
const { withSelfie } = require('./selfieHelper');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE } } };

function setup({ seed = {}, build = {} } = {}) {
  const db = fakeDb({
    'orders/o1': { status: 'broadcast', budget: 500, description: 'Course', notifiedDriverIds: ['d1', 'd2', 'd3'] },
    'livreurs/d1': { wallet: 1000, isOnline: true, pendingOrderId: 'o1' },
    'livreurs/d2': { wallet: 1000, isOnline: true, pendingOrderId: 'o1' },
    'livreurs/d3': { wallet: 1000, isOnline: true, pendingOrderId: 'o1' },
    ...seed,
  });
  // Firestore sérialise les transactions concurrentes qui se disputent un document (la perdante rejoue et voit l'état gagnant) ;
  // le faux Firestore n'a pas ce comportement : on l'impose ici.
  const rawRunTransaction = db.runTransaction;
  let tail = Promise.resolve();
  db.runTransaction = (cb) => { const next = tail.then(() => rawRunTransaction(cb)); tail = next.catch(() => {}); return next; };
  const run = withSelfie(buildAcceptOrder({
    db, admin, onCall: (handler) => ({ run: handler }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, ...build,
  }).run);
  const req = (uid, orderId = 'o1') => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId } });
  return { db, run, req };
}
const get = (h, path) => h.db.store.get(path);
const commissions = (h) => [...h.db.store.keys()].filter((k) => k.includes('/wallet_transactions/commission_'));

test('deux livreurs acceptent en même temps : un seul gagne, une seule commission, offres de tous nettoyées', async () => {
  const h = setup();
  const results = await Promise.allSettled([h.run(h.req('d1')), h.run(h.req('d2'))]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const lost = results.find((r) => r.status === 'rejected');
  assert.equal(lost.reason.code, 'failed-precondition');
  const winner = get(h, 'orders/o1').driverId;
  const loser = winner === 'd1' ? 'd2' : 'd1';
  assert.equal(get(h, 'orders/o1').status, 'accepted');
  assert.equal(commissions(h).length, 1);
  assert.equal(get(h, `livreurs/${winner}`).wallet, 900);
  assert.equal(get(h, `livreurs/${loser}`).wallet, 1000);
  assert.equal(get(h, `livreurs/${winner}`).isOnDelivery, true);
  assert.notEqual(get(h, `livreurs/${loser}`).isOnDelivery, true);
  for (const id of ['d1', 'd2', 'd3']) assert.equal(get(h, `livreurs/${id}`).pendingOrderId, undefined, id);
});

test('livreur occupé sur une autre commande : son offre pour une autre commande est conservée', async () => {
  const h = setup({ seed: { 'livreurs/d2': { wallet: 1000, isOnline: true, isOnDelivery: true, pendingOrderId: 'other' },
    'livreurs/d3': { wallet: 700, isOnline: true, isOnDelivery: true, currentOrderId: 'other', pendingOrderId: 'o1' } } });
  await h.run(h.req('d1'));
  assert.equal(get(h, 'livreurs/d1').pendingOrderId, undefined);
  assert.equal(get(h, 'livreurs/d2').pendingOrderId, 'other');
  assert.equal(get(h, 'livreurs/d2').isOnDelivery, true);
  assert.equal(get(h, 'livreurs/d3').pendingOrderId, undefined);
  assert.equal(get(h, 'livreurs/d3').isOnDelivery, true); // le nettoyage ne libère jamais un livreur
  assert.equal(get(h, 'livreurs/d3').currentOrderId, 'other');
  assert.equal(get(h, 'livreurs/d3').wallet, 700);
});

test('rejeu de l\'acceptation et répétition du nettoyage : aucun second prélèvement, état identique', async () => {
  const h = setup();
  await h.run(h.req('d1'));
  const snapshot = JSON.stringify([...h.db.store]);
  const replay = await h.run(h.req('d1'));
  assert.equal(replay.alreadyAccepted, true);
  await clearAcceptedOffers(h.db, admin, 'o1', { notifiedDriverIds: ['d1', 'd2', 'd3'] });
  await clearAcceptedOffers(h.db, admin, 'o1', { notifiedDriverIds: ['d1', 'd2', 'd3'] }, 'd1');
  assert.equal(JSON.stringify([...h.db.store]), snapshot);
  assert.equal(commissions(h).length, 1);
});

test('erreur Firestore pendant le nettoyage : l\'acceptation reste valide, commission unique, rien n\'est propagé', async () => {
  const errors = [];
  const original = console.error; console.error = (...a) => errors.push(a.join(' '));
  try {
    const h = setup({ build: { clearOffers: async () => { throw Object.assign(new Error('UNAVAILABLE'), { code: 14 }); } } });
    const result = await h.run(h.req('d1'));
    assert.deepEqual(result, { success: true, alreadyAccepted: false, commission: 100 });
    assert.equal(get(h, 'orders/o1').status, 'accepted');
    assert.equal(get(h, 'livreurs/d1').wallet, 900);
    assert.equal(commissions(h).length, 1);
    assert.equal(get(h, 'livreurs/d2').pendingOrderId, 'o1'); // laissé au déclencheur
    assert.equal(errors.length, 1);
    // Filet de secours : le déclencheur, avec l'état « avant » de la commande, termine le travail.
    await clearAcceptedOffers(h.db, admin, 'o1', { notifiedDriverIds: ['d1', 'd2', 'd3'] });
    for (const id of ['d1', 'd2', 'd3']) assert.equal(get(h, `livreurs/${id}`).pendingOrderId, undefined);
    assert.equal(commissions(h).length, 1);
  } finally { console.error = original; }
});

test('nettoyage bloqué : la réponse au livreur est rendue dans le budget de temps', async () => {
  const h = setup({ build: { clearOffers: () => new Promise(() => {}), offerCleanupTimeoutMs: 30 } });
  const started = Date.now();
  const result = await h.run(h.req('d1'));
  assert.equal(result.success, true);
  assert.ok(Date.now() - started < 1000);
});

test('refus d\'acceptation : aucun nettoyage, offres des autres intactes', async () => {
  let calls = 0;
  const h = setup({ seed: { 'livreurs/d1': { wallet: 10, isOnline: true, pendingOrderId: 'o1' } },
    build: { clearOffers: async () => { calls++; } } });
  await assert.rejects(() => h.run(h.req('d1')), /CREDIT_INSUFFISANT/);
  assert.equal(calls, 0);
  assert.equal(get(h, 'livreurs/d2').pendingOrderId, 'o1');
  assert.equal(get(h, 'orders/o1').status, 'broadcast');
});

test('le nettoyage ne s\'applique pas si la commande n\'est plus acceptée par ce livreur (annulée, reprise par un autre)', async () => {
  const h = setup();
  await h.run(h.req('d1'));
  await h.db.runTransaction(async (tx) => { tx.update(h.db.collection('orders').doc('o1'), { driverId: 'dX' }); });
  await h.db.runTransaction(async (tx) => { tx.update(h.db.collection('livreurs').doc('d2'), { pendingOrderId: 'o1' }); });
  await clearAcceptedOffers(h.db, admin, 'o1', { notifiedDriverIds: ['d2'] }, 'd1');
  assert.equal(get(h, 'livreurs/d2').pendingOrderId, 'o1'); // propriétaire différent : rien touché
  await h.db.runTransaction(async (tx) => { tx.update(h.db.collection('orders').doc('o1'), { status: 'cancelled', driverId: 'd1' }); });
  await clearAcceptedOffers(h.db, admin, 'o1', { notifiedDriverIds: ['d2'] }, 'd1');
  assert.equal(get(h, 'livreurs/d2').pendingOrderId, 'o1'); // plus « accepted » : rien touché
});

test('compatibilité avec syncDriverOrderLifecycle : le passage du déclencheur après le nettoyage synchrone ne change rien', async () => {
  const h = setup();
  const before = { status: 'broadcast', notifiedDriverIds: ['d1', 'd2', 'd3'] };
  await h.run(h.req('d1'));
  const afterSync = JSON.stringify([...h.db.store]);
  await clearAcceptedOffers(h.db, admin, 'o1', before); // ce que fait le déclencheur sur l'événement d'acceptation
  assert.equal(JSON.stringify([...h.db.store]), afterSync);
  assert.equal(get(h, 'livreurs/d1').wallet, 900);
});
