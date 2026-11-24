'use strict';

// Mission 7E-34 — confirmations QR/PIN concurrentes contre le VRAI moteur de l'émulateur Firestore (jamais la production) :
// vraies transactions, vrais conflits et reprises. Données fictives, pepper de test, aucun FCM.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-proofs \
//     "node --test functions/test/deliveryProofs.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && /^demo-/.test(process.env.GCLOUD_PROJECT || '');
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-*)' };
const PEPPER = 'emulator-test-only-pepper-not-a-secret';

let admin; let db; let deliver; let pickup; let proofs;

test.before(async () => {
  if (!emulated) return;
  process.env.DELIVERY_PROOF_PEPPER = PEPPER;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  const { onCall, HttpsError } = require('firebase-functions/v2/https');
  proofs = require('../deliveryProofs');
  const { buildDeliverOrderWithProof } = require('../orderActions');
  const deps = {
    db, admin, onCall, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission: async () => 100,
    deliveryProofPepper: { name: 'DELIVERY_PROOF_PEPPER' },
  };
  deliver = buildDeliverOrderWithProof(deps);
  pickup = proofs.buildConfirmPickupWithProof(deps);
});

const call = (fn, uid, orderId, data) => fn.run({ auth: { uid }, data: { orderId, ...data } });
const TOKEN = 'emulator-delivery-token-0123456789';
const PIN = '246810';
const proofPath = (id, type) => `delivery_proofs/${proofs.sessionId(id, type)}/versions/pv1`;

async function seedOrder(id, { type = 'delivery', order = {} } = {}) {
  await db.doc(`orders/${id}`).set({
    clientId: 'c1', driverId: 'd1', status: type === 'pickup' ? 'accepted' : 'picked_up', deliveryProofMode: 'qr_v1',
    driverAssignmentVersion: 1, paymentMethod: 'wallet', isPaid: true, budget: 1000, shoppingBudget: 0,
    commissionStatus: 'charged', commissionAmount: 100, commissionPayerId: 'd1', commissionTxId: `commission_${id}_d1`, ...order,
  });
  const session = `delivery_proofs/${proofs.sessionId(id, type)}`;
  await db.doc(session).set({ orderId: id, type, currentProofId: 'pv1', driverId: 'd1', assignmentVersion: 1 });
  await db.doc(`${session}/versions/pv1`).set({
    orderId: id, type, tokenHash: proofs.hashToken(TOKEN), pinHash: proofs.hashPin(PIN, PEPPER, id, type), status: 'active',
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 600000), driverId: 'd1', assignmentVersion: 1, pinAttempts: 0,
  });
}
async function reset() {
  await db.doc('livreurs/d1').set({ wallet: 300, isOnDelivery: true, deliveries: 0 });
  await db.doc('livreurs/d2').set({ wallet: 500, isOnDelivery: false });
  await db.doc('restaurants/r1').set({ wallet: 100 });
}
const wallets = async () => ({
  d1: (await db.doc('livreurs/d1').get()).data().wallet,
  d2: (await db.doc('livreurs/d2').get()).data().wallet,
  r1: (await db.doc('restaurants/r1').get()).data().wallet,
});
// Mouvements d'argent journalisés pour une commande : écritures du livreur, du partenaire et commissions.
async function movements(orderId) {
  const out = [];
  for (const path of ['livreurs/d1', 'livreurs/d2', 'restaurants/r1']) {
    for (const d of (await db.collection(`${path}/wallet_transactions`).get()).docs) {
      if (d.data().orderId === orderId || d.id.includes(orderId)) out.push(`${path}/${d.data().type || d.id}`);
    }
  }
  for (const d of (await db.collection('commissions').get()).docs) {
    if (d.data().orderId === orderId || d.id.includes(orderId)) out.push('commissions/#'); // identifiant aléatoire : on compte les écritures
  }
  return out.sort();
}
const fulfilled = (results) => results.filter((r) => r.status === 'fulfilled').length;
const SHAPES = {
  partenaire: { sellerId: 'r1', sellerType: 'restaurant' }, // le partenaire est crédité
  livreur: {}, // livraison simple payée par wallet : le livreur est crédité
};

for (const [name, shape] of Object.entries(SHAPES)) {
  test(`livraison ${name} : 4 QR + 4 PIN simultanés → une livraison, crédits et commission identiques à une exécution isolée`, options, async () => {
    await reset();
    await seedOrder(`ref-${name}`, { order: shape });
    assert.deepEqual(await call(deliver, 'd1', `ref-${name}`, { proofToken: TOKEN }), { success: true });
    const reference = await wallets();
    const referenceMoves = (await movements(`ref-${name}`)).map((m) => m.replace(`ref-${name}`, 'X'));

    await reset();
    await seedOrder(`cc-${name}`, { order: shape });
    const results = await Promise.allSettled([
      ...Array.from({ length: 4 }, () => call(deliver, 'd1', `cc-${name}`, { proofToken: TOKEN })),
      ...Array.from({ length: 4 }, () => call(deliver, 'd1', `cc-${name}`, { proofPin: PIN })),
    ]);
    const failures = results.filter((r) => r.status === 'rejected');
    assert.equal(fulfilled(results), 1, `une seule confirmation réussit (échecs : ${failures.map((r) => r.reason?.code).join(',')})`);
    for (const r of failures) assert.ok(['failed-precondition', 'aborted'].includes(r.reason.code), r.reason.code);

    const order = (await db.doc(`orders/cc-${name}`).get()).data();
    assert.equal(order.status, 'delivered');
    assert.equal(order.deliveryProofValidatedBy, 'd1');
    assert.deepEqual(await wallets(), reference, 'crédits livreur et partenaire identiques à une seule exécution');
    assert.deepEqual((await movements(`cc-${name}`)).map((m) => m.replace(`cc-${name}`, 'X')), referenceMoves, 'mêmes écritures de journal, sans doublon');
    assert.equal((await db.doc(proofPath(`cc-${name}`, 'delivery')).get()).data().status, 'used');

    // Rejeu (réponse perdue côté client) : refusé, rien ne bouge.
    const before = JSON.stringify(await wallets());
    await assert.rejects(call(deliver, 'd1', `cc-${name}`, { proofPin: PIN }), (e) => e.code === 'failed-precondition');
    await assert.rejects(call(deliver, 'd1', `cc-${name}`, { proofToken: TOKEN }), (e) => e.code === 'failed-precondition');
    assert.equal(JSON.stringify(await wallets()), before);
  });
}

test('le crédit est bien effectué une fois (contrôle de non-trivialité de la comparaison)', options, async () => {
  await reset();
  await seedOrder('nt1', { order: SHAPES.partenaire });
  await call(deliver, 'd1', 'nt1', { proofToken: TOKEN });
  assert.equal((await wallets()).r1, 1100);
  await reset();
  await seedOrder('nt2', { order: SHAPES.livreur });
  await call(deliver, 'd1', 'nt2', { proofPin: PIN });
  assert.ok((await wallets()).d1 > 300, 'le livreur est crédité pour une livraison simple payée par wallet');
});

test('mauvais livreur, commande annulée, commande déjà livrée : refus, aucun mouvement, preuve intacte', options, async () => {
  await reset();
  await seedOrder('bad1', { order: SHAPES.partenaire });
  await seedOrder('can1', { order: { ...SHAPES.partenaire, status: 'cancelled' } });
  await seedOrder('del1', { order: { ...SHAPES.partenaire, status: 'delivered' } });
  const before = JSON.stringify(await wallets());
  const [wrong, cancelled, delivered] = await Promise.allSettled([
    call(deliver, 'd2', 'bad1', { proofToken: TOKEN }),
    call(deliver, 'd1', 'can1', { proofToken: TOKEN }),
    call(deliver, 'd1', 'del1', { proofToken: TOKEN }),
  ]);
  assert.equal(wrong.reason.code, 'permission-denied');
  assert.equal(cancelled.reason.code, 'failed-precondition');
  assert.equal(delivered.reason.code, 'failed-precondition');
  assert.equal(JSON.stringify(await wallets()), before);
  for (const id of ['bad1', 'can1', 'del1']) {
    assert.equal((await db.doc(proofPath(id, 'delivery')).get()).data().status, 'active', id);
  }
  assert.equal((await db.doc('orders/bad1').get()).data().status, 'picked_up');
});

test('preuve d’une autre commande : refusée (le PIN est lié à la commande)', options, async () => {
  await reset();
  await seedOrder('x1', { order: SHAPES.partenaire });
  await seedOrder('x2', { order: SHAPES.partenaire });
  const pinOfX1 = (await db.doc(proofPath('x1', 'delivery')).get()).data().pinHash;
  await db.doc(proofPath('x2', 'delivery')).update({ pinHash: pinOfX1 });
  await assert.rejects(call(deliver, 'd1', 'x2', { proofPin: PIN }), (e) => e.code === 'failed-precondition');
  assert.equal((await db.doc('orders/x2').get()).data().status, 'picked_up');
});

test('récupération : 3 QR + 3 PIN simultanés → un seul passage à picked_up, preuve consommée une fois', options, async () => {
  await reset();
  await seedOrder('pk1', { type: 'pickup', order: SHAPES.partenaire });
  const results = await Promise.allSettled([
    ...Array.from({ length: 3 }, () => call(pickup, 'd1', 'pk1', { token: TOKEN })),
    ...Array.from({ length: 3 }, () => call(pickup, 'd1', 'pk1', { pin: PIN })),
  ]);
  assert.equal(fulfilled(results), 1);
  assert.equal((await db.doc('orders/pk1').get()).data().status, 'picked_up');
  assert.equal((await db.doc(proofPath('pk1', 'pickup')).get()).data().status, 'used');
  await assert.rejects(call(pickup, 'd1', 'pk1', { pin: PIN }), (e) => e.code === 'failed-precondition');
  await assert.rejects(call(pickup, 'd2', 'pk1', { pin: PIN }), (e) => e.code === 'permission-denied');
});
