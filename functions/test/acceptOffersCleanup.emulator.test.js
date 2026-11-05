'use strict';

// Mission 7E-27 — acceptations concurrentes et nettoyage des offres contre l'émulateur Firestore (jamais la production) :
// vraies transactions, vrais conflits. Données fictives uniquement.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-accept \
//     "node --test functions/test/acceptOffersCleanup.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };

let admin; let db; let accept; let clearAcceptedOffers; let buildAcceptOrder; let HttpsError; let calculateCommission; let withSelfie;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  ({ HttpsError } = require('firebase-functions/v2/https'));
  ({ buildAcceptOrder } = require('../driverAcceptance'));
  ({ clearAcceptedOffers } = require('../driverLifecycle'));
  ({ calculateCommission } = require('../dispatch'));
  ({ withSelfie } = require('./selfieHelper'));
});

const make = (extra = {}) => withSelfie(buildAcceptOrder({
  db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, ...extra,
}).run);
const req = (uid, orderId) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { orderId } });

async function seed(orderId, drivers) {
  await db.doc(`orders/${orderId}`).set({ status: 'broadcast', budget: 500, description: 'Course', notifiedDriverIds: Object.keys(drivers) });
  for (const [id, d] of Object.entries(drivers)) await db.doc(`livreurs/${id}`).set({ wallet: 1000, isOnline: true, ...d });
}
const commissionDocs = async (ids) => {
  const out = [];
  for (const id of ids) out.push(...(await db.collection(`livreurs/${id}/wallet_transactions`).get()).docs.map((d) => `${id}/${d.id}`));
  return out;
};

test('5 livreurs acceptent en même temps : une acceptation, une commission, offres nettoyées, occupés ailleurs intacts', options, async () => {
  const o = 'cc1';
  await seed(o, {
    a1: { pendingOrderId: o }, a2: { pendingOrderId: o }, a3: { pendingOrderId: o },
    busy: { isOnDelivery: true, currentOrderId: 'autre', pendingOrderId: o, wallet: 700 },
    other: { pendingOrderId: 'autre-offre' },
  });
  accept = make();
  const results = await Promise.allSettled(['a1', 'a2', 'a3', 'busy', 'other'].map((uid) => accept(req(uid, o))));
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1, JSON.stringify(results.map((r) => r.reason?.message)));
  const order = (await db.doc(`orders/${o}`).get()).data();
  assert.equal(order.status, 'accepted');
  const winner = order.driverId;
  assert.deepEqual(await commissionDocs(['a1', 'a2', 'a3', 'busy', 'other']), [`${winner}/commission_${o}_${winner}`]);
  assert.equal((await db.doc(`livreurs/${winner}`).get()).data().wallet, 900);
  for (const id of ['a1', 'a2', 'a3', 'busy', 'other']) {
    const d = (await db.doc(`livreurs/${id}`).get()).data();
    if (id !== winner) assert.ok(d.wallet === 1000 || (id === 'busy' && d.wallet === 700), `${id} portefeuille inchangé`);
    if (id === 'other') assert.equal(d.pendingOrderId, 'autre-offre');
    else assert.equal(d.pendingOrderId, undefined, `${id} offre périmée supprimée`);
  }
  const busy = (await db.doc('livreurs/busy').get()).data();
  assert.equal(busy.isOnDelivery, true);
  assert.equal(busy.currentOrderId, 'autre');
  assert.equal((await db.doc(`livreurs/${winner}`).get()).data().isOnDelivery, true);
});

test('rejeu du gagnant et déclencheur après nettoyage : aucun second prélèvement, état identique', options, async () => {
  const o = 'cc2';
  await seed(o, { b1: { pendingOrderId: o }, b2: { pendingOrderId: o } });
  accept = make();
  await accept(req('b1', o));
  const snapshot = async () => JSON.stringify([(await db.doc(`orders/${o}`).get()).data(), (await db.doc('livreurs/b1').get()).data(), (await db.doc('livreurs/b2').get()).data()]);
  const before = await snapshot();
  const replay = await accept(req('b1', o));
  assert.equal(replay.alreadyAccepted, true);
  await clearAcceptedOffers(db, admin, o, { notifiedDriverIds: ['b1', 'b2'] });
  await clearAcceptedOffers(db, admin, o, { notifiedDriverIds: ['b1', 'b2'] }, 'b1');
  assert.equal(await snapshot(), before);
  assert.equal((await commissionDocs(['b1', 'b2'])).length, 1);
});

test('erreur du nettoyage : acceptation valide, offres reprises par le déclencheur, toujours une seule commission', options, async () => {
  const o = 'cc3';
  await seed(o, { c1: { pendingOrderId: o }, c2: { pendingOrderId: o } });
  const original = console.error; console.error = () => {};
  try {
    accept = make({ clearOffers: async () => { throw Object.assign(new Error('UNAVAILABLE'), { code: 14 }); } });
    const result = await accept(req('c1', o));
    assert.equal(result.success, true);
  } finally { console.error = original; }
  assert.equal((await db.doc('livreurs/c2').get()).data().pendingOrderId, o);
  await clearAcceptedOffers(db, admin, o, { notifiedDriverIds: ['c1', 'c2'] });
  assert.equal((await db.doc('livreurs/c2').get()).data().pendingOrderId, undefined);
  assert.equal((await commissionDocs(['c1', 'c2'])).length, 1);
});

test('commande annulée ou reprise avant le nettoyage : aucune offre touchée', options, async () => {
  const o = 'cc4';
  await seed(o, { d1: { pendingOrderId: o }, d2: { pendingOrderId: o } });
  accept = make({ clearOffers: async () => {} });
  await accept(req('d1', o));
  await db.doc(`orders/${o}`).update({ status: 'cancelled' });
  await clearAcceptedOffers(db, admin, o, { notifiedDriverIds: ['d1', 'd2'] }, 'd1');
  assert.equal((await db.doc('livreurs/d2').get()).data().pendingOrderId, o);
  assert.equal((await db.doc('livreurs/d1').get()).data().isOnDelivery, true); // jamais libéré par ce nettoyage
});
