'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildSettleTransferEarnings } = require('../transferSettlement');
const { buildProposal, settlementDocument } = require('../earningsSettlement');

const admin = {
  firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion } },
};

const baseOrder = (extra = {}) => ({
  clientId: 'c1', status: 'delivered', driverId: 'dB', budget: 1000, settlementHold: true,
  latitude: 6.70, longitude: -3.49, destLat: 6.80, destLng: -3.49, pickedUpAt: 1, deliveryPhoto: 'p.jpg',
  commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
  driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10,
    handover: { trusted: true, point: { lat: 6.74, lng: -3.49 } } }],
  ...extra,
});

function setup({ method = 'wallet', orderExtra = {}, settlementExtra = {} } = {}) {
  const order = baseOrder(orderExtra);
  const settlement = { ...settlementDocument('o1', order, method, 1000), ...settlementExtra };
  const db = fakeDb({
    'orders/o1': order,
    'transfer_settlements/o1': settlement,
    'livreurs/dA': { wallet: 300 },
    'livreurs/dB': { wallet: 0 },
    'admins/root': { role: 'super', isActive: true },
  });
  const requireSuperAdmin = async ({ request }) => {
    if (request.auth.uid !== 'root') throw new HttpsError('permission-denied', 'Réservé à l’administrateur principal.');
  };
  const run = buildSettleTransferEarnings({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, requireSuperAdmin,
  }).run;
  const call = (uid, data) => run({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  return { db, call };
}
const get = (h, p) => h.db.store.get(p);
const ledger = (h) => [...h.db.store.keys()].filter((k) => k.includes('wallet_transactions'));

test('wallet : validation admin crédite chaque livreur, hold libéré, somme = prix payé', async () => {
  const h = setup();
  const s = get(h, 'transfer_settlements/o1');
  assert.equal(s.status, 'pending_review');
  const r = await h.call('root', { action: 'approve', orderId: 'o1' });
  assert.equal(r.status, 'settled');
  const a = get(h, 'livreurs/dA').wallet - 300;
  const b = get(h, 'livreurs/dB').wallet;
  assert.equal(a + b, 1000);
  assert.ok(a > b - 1000 && Math.abs(a - 520) <= 1 && Math.abs(b - 480) <= 1);
  assert.equal(get(h, 'orders/o1').settlementHold, false);
  assert.equal(get(h, 'orders/o1').settlementStatus, 'settled');
  assert.equal(ledger(h).length, 2);
  assert.equal(get(h, 'transfer_settlements/o1').decisions[0].byUid, 'root');
});

test('double validation / rejeu : aucun double crédit', async () => {
  const h = setup();
  await h.call('root', { action: 'approve', orderId: 'o1' });
  const walletsAfter = [get(h, 'livreurs/dA').wallet, get(h, 'livreurs/dB').wallet];
  const again = await h.call('root', { action: 'approve', orderId: 'o1' });
  assert.equal(again.replay, true);
  assert.deepEqual([get(h, 'livreurs/dA').wallet, get(h, 'livreurs/dB').wallet], walletsAfter);
  assert.equal(ledger(h).length, 2);
  // Même un état incohérent (statut remis en revue) ne peut pas recréditer : mouvement déjà présent.
  get(h, 'transfer_settlements/o1').status = 'pending_review';
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1' }), /attente de règlement/);
  get(h, 'orders/o1').settlementHold = true;
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1' }), /déjà enregistré/);
  assert.deepEqual([get(h, 'livreurs/dA').wallet, get(h, 'livreurs/dB').wallet], walletsAfter);
});

test('accès non autorisé : livreur, client, anonyme', async () => {
  const h = setup();
  for (const uid of ['dA', 'dB', 'c1']) {
    await assert.rejects(h.call(uid, { action: 'approve', orderId: 'o1' }), { code: 'permission-denied' });
    await assert.rejects(h.call(uid, { action: 'closeCash', orderId: 'o1' }), { code: 'permission-denied' });
  }
  await assert.rejects(h.call('root', { action: 'zzz', orderId: 'o1' }), { code: 'invalid-argument' });
  assert.equal(get(h, 'livreurs/dA').wallet, 300);
});

test('données insuffisantes : approbation refusée sans répartition corrigée justifiée', async () => {
  const h = setup({ orderExtra: { driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10 }] } });
  assert.equal(get(h, 'transfer_settlements/o1').proposal.credits, null);
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1' }), /Données insuffisantes/);
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1', credits: { dA: 500, dB: 500 } }), { code: 'invalid-argument' });
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1', credits: { dA: 600, dB: 500 }, justification: 'GPS vérifié avec les deux livreurs' }), /somme/);
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1', credits: { dA: 500, dX: 500 }, justification: 'GPS vérifié avec les deux livreurs' }), /étranger/);
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1', credits: { dA: -100, dB: 1100 }, justification: 'GPS vérifié avec les deux livreurs' }), { code: 'invalid-argument' });
  assert.equal(get(h, 'livreurs/dB').wallet, 0);
  const ok = await h.call('root', { action: 'approve', orderId: 'o1', credits: { dA: 550, dB: 450 }, justification: 'GPS vérifié avec les deux livreurs' });
  assert.equal(ok.status, 'settled');
  assert.equal(get(h, 'livreurs/dA').wallet, 850);
  assert.equal(get(h, 'transfer_settlements/o1').overridden, true);
  assert.match(get(h, 'transfer_settlements/o1').decisions[0].justification, /GPS/);
});

test('commande annulée ou non retenue : aucun règlement', async () => {
  const h = setup({ orderExtra: { settlementHold: false } });
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1' }), { code: 'failed-precondition' });
  assert.equal(ledger(h).length, 0);
});

test('livreur introuvable : aucune écriture partielle', async () => {
  const h = setup();
  h.db.store.delete('livreurs/dB');
  await assert.rejects(h.call('root', { action: 'approve', orderId: 'o1' }), /introuvable/);
  assert.equal(get(h, 'livreurs/dA').wallet, 300);
  assert.equal(get(h, 'transfer_settlements/o1').status, 'pending_review');
});

test('cash : aucun mouvement de wallet, montants à régulariser, confirmation puis clôture', async () => {
  const h = setup({ method: 'cash' });
  const s0 = get(h, 'transfer_settlements/o1');
  assert.equal(s0.holderDriverId, 'dB');
  assert.equal(s0.cash.collected, 1000);
  const r = await h.call('root', { action: 'approve', orderId: 'o1' });
  assert.equal(r.status, 'cash_pending');
  assert.equal(get(h, 'livreurs/dA').wallet, 300);
  assert.equal(get(h, 'livreurs/dB').wallet, 0);
  assert.equal(ledger(h).length, 0);
  assert.equal(r.toRegularize.length, 1);
  assert.deepEqual([r.toRegularize[0].from, r.toRegularize[0].to], ['dB', 'dA']);
  assert.ok(Math.abs(r.toRegularize[0].amount - 520) <= 1);
  assert.equal(get(h, 'orders/o1').settlementHold, true); // reste retenu jusqu’au règlement

  // règlement non confirmé : clôture refusée sans justification
  await assert.rejects(h.call('root', { action: 'closeCash', orderId: 'o1' }), /justification/);
  // le détenteur des espèces ou un tiers ne peut pas confirmer une réception
  await assert.rejects(h.call('dB', { action: 'confirmCashReceipt', orderId: 'o1' }), { code: 'permission-denied' });
  await assert.rejects(h.call('dZ', { action: 'confirmCashReceipt', orderId: 'o1' }), { code: 'permission-denied' });
  await h.call('dA', { action: 'confirmCashReceipt', orderId: 'o1' });
  assert.equal((await h.call('dA', { action: 'confirmCashReceipt', orderId: 'o1' })).replay, true);
  const closed = await h.call('root', { action: 'closeCash', orderId: 'o1' });
  assert.equal(closed.status, 'settled');
  assert.equal(get(h, 'orders/o1').settlementHold, false);
  assert.equal(get(h, 'livreurs/dB').wallet, 0); // jamais débité automatiquement
  assert.equal((await h.call('root', { action: 'closeCash', orderId: 'o1' })).replay, true);
});

test('cash non confirmé : clôture possible seulement avec justification administrative', async () => {
  const h = setup({ method: 'cash' });
  await h.call('root', { action: 'approve', orderId: 'o1' });
  const closed = await h.call('root', { action: 'closeCash', orderId: 'o1', justification: 'Remise constatée par téléphone avec A' });
  assert.equal(closed.status, 'settled');
  const last = get(h, 'transfer_settlements/o1').decisions.at(-1);
  assert.deepEqual(last.unconfirmed, ['dA']);
});

test('cash : approuver puis tenter un crédit wallet est impossible (méthode cash)', async () => {
  const h = setup({ method: 'cash' });
  await h.call('root', { action: 'approve', orderId: 'o1' });
  assert.equal(ledger(h).length, 0);
  await assert.rejects(h.call('dA', { action: 'confirmCashReceipt', orderId: 'nope' }), { code: 'not-found' });
});

test('la proposition conserve le calcul détaillé pour audit', () => {
  const p = buildProposal(baseOrder(), { deliveredAtMs: 5 });
  assert.equal(p.legs.length, 2);
  assert.ok(p.waypoints.length === 3 && p.waypoints.every(Boolean));
  assert.equal(p.evidence.pickupProof && p.evidence.handoverProofs && p.evidence.deliveryProof, true);
});
