'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildReleaseOrderBeforePickup } = require('../driverRelease');
const { buildAcceptOrder } = require('../driverAcceptance');
const { withSelfie } = require('./selfieHelper');
const { calculateCommission, DispatchError } = require('../dispatch');

const admin = {
  firestore: { FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion } },
};

function setup({ order = {}, extra = {}, dispatchResult = { dispatched: true, mode: 'assigned' }, dispatchError } = {}) {
  const db = fakeDb({
    'orders/o1': {
      clientId: 'c1', driverId: 'dA', status: 'accepted', budget: 1500, paymentMethod: 'cash',
      latitude: 6.73, longitude: -3.49, destLat: 6.74, destLng: -3.5, pickupCityId: 'abengourou',
      cityResolutionStatus: 'resolved', description: 'Course test',
      commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
      commissionTxId: 'commission_o1_dA', driverAcceptanceSelfie: 'x', ...order,
    },
    'livreurs/dA': { wallet: 300, isOnline: true, isOnDelivery: true },
    'livreurs/dB': { wallet: 1000, isOnline: true },
    ...extra,
  });
  const audits = [], dispatches = [];
  const release = buildReleaseOrderBeforePickup({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); },
    calculateCommission,
    dispatchOrder: async (_db, _admin, args) => {
      dispatches.push(args);
      if (dispatchError) throw dispatchError;
      return dispatchResult;
    },
    DispatchError,
  }).run;
  const accept = withSelfie(buildAcceptOrder({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run);
  const req = (data, uid = 'dA') => ({
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data,
  });
  return { db, release, accept, req, audits, dispatches };
}
const order = (h) => h.db.store.get('orders/o1');
const wallet = (h, id) => h.db.store.get(`livreurs/${id}`).wallet;
const ledgerKeys = (h, id) => [...h.db.store.keys()].filter((k) => k.startsWith(`livreurs/${id}/wallet_transactions/`));
const assignTo = (h, id) => h.db.store.set('orders/o1', { ...order(h), status: 'assigned', driverId: id });

test('libération avant récupération : commission remboursée une fois, commande remise en file intacte', async () => {
  const h = setup();
  const result = await h.release(h.req({ orderId: 'o1', reason: 'vehicle_problem' }));
  assert.equal(result.success, true);
  assert.equal(result.commissionRefunded, 200);
  assert.equal(result.dispatched, true);
  const o = order(h);
  assert.equal(o.status, 'pending');
  assert.equal('driverId' in o, false);
  assert.equal('driverAcceptanceSelfie' in o, false);
  // Identité, prix et client inchangés.
  assert.equal(o.budget, 1500);
  assert.equal(o.clientId, 'c1');
  assert.equal(o.paymentMethod, 'cash');
  assert.equal(o.commissionStatus, 'refunded');
  assert.equal(o.driverAssignmentVersion, 2, 'les preuves liées à A sont invalidées');
  assert.equal(o.transferCount, 1);
  assert.deepEqual(o.excludedDriverIds, ['dA']);
  assert.equal(o.driverHistory.length, 1);
  assert.equal(o.driverHistory[0].driverId, 'dA');
  assert.equal(o.driverHistory[0].phase, 'before_pickup');
  assert.equal(wallet(h, 'dA'), 500, '300 + 200 remboursés, aucun gain de livraison');
  assert.equal(h.db.store.get('livreurs/dA').isOnDelivery, false);
  assert.deepEqual(ledgerKeys(h, 'dA'), ['livreurs/dA/wallet_transactions/commission_refund_o1_dA']);
  assert.equal(h.audits.length, 1);
});

test('rejeu (double appui) : aucun second remboursement', async () => {
  const h = setup();
  await h.release(h.req({ orderId: 'o1', reason: 'emergency' }));
  const again = await h.release(h.req({ orderId: 'o1', reason: 'emergency' }));
  assert.equal(again.replay, true);
  assert.equal(wallet(h, 'dA'), 500);
  assert.equal(ledgerKeys(h, 'dA').length, 1);
  assert.equal(order(h).transferCount, 1);
  assert.equal(h.audits.length, 1);
});

test('re-dispatch sans A, avec les données de la commande', async () => {
  const h = setup();
  await h.release(h.req({ orderId: 'o1', reason: 'too_far' }));
  assert.equal(h.dispatches.length, 1);
  assert.deepEqual(h.dispatches[0].excludedDriverIds, ['dA']);
  assert.equal(h.dispatches[0].orderId, 'o1');
  assert.equal(h.dispatches[0].budget, 1500);
  assert.equal(h.dispatches[0].pickupCityId, 'abengourou');
});

test('aucun livreur disponible : la commande reste pending (recoveryPending), rien n’est perdu', async () => {
  const h = setup({ dispatchResult: { dispatched: false, mode: 'none' } });
  const result = await h.release(h.req({ orderId: 'o1', reason: 'other' }));
  assert.equal(result.recoveryPending, true);
  assert.equal(order(h).status, 'pending');
  assert.equal(wallet(h, 'dA'), 500);
});

test('échec du dispatch (erreur technique) : libération conservée, pas de double remboursement au rejeu', async () => {
  const h = setup({ dispatchError: new Error('boom') });
  const result = await h.release(h.req({ orderId: 'o1', reason: 'other' }));
  assert.equal(result.recoveryPending, true);
  const again = await h.release(h.req({ orderId: 'o1', reason: 'other' }));
  assert.equal(again.replay, true);
  assert.equal(wallet(h, 'dA'), 500);
});

test('B accepte : sa commission est prélevée une seule fois ; A ne peut pas reprendre la commande', async () => {
  const h = setup();
  await h.release(h.req({ orderId: 'o1', reason: 'vehicle_problem' }));
  assignTo(h, 'dB');
  await assert.rejects(h.accept(h.req({ orderId: 'o1' }, 'dA')), (e) => e.code === 'permission-denied');
  const accepted = await h.accept(h.req({ orderId: 'o1' }, 'dB'));
  assert.equal(accepted.commission, 200);
  assert.equal(wallet(h, 'dB'), 800);
  assert.equal(order(h).commissionPayerId, 'dB');
  assert.equal(order(h).commissionStatus, 'charged');
  assert.equal(order(h).budget, 1500, 'le client ne paie aucun supplément');
  assert.deepEqual(ledgerKeys(h, 'dB'), ['livreurs/dB/wallet_transactions/commission_o1_dB']);
  // Une seule commission nette : A remboursé, B prélevé.
  assert.equal(wallet(h, 'dA'), 500);
  // Historique : A conservé, B est le livreur courant.
  assert.equal(order(h).driverHistory[0].driverId, 'dA');
  assert.equal(order(h).driverId, 'dB');
});

test('B avec solde insuffisant ne peut pas accepter', async () => {
  const h = setup({ extra: { 'livreurs/dB': { wallet: 50, isOnline: true } } });
  await h.release(h.req({ orderId: 'o1', reason: 'other' }));
  assignTo(h, 'dB');
  await assert.rejects(h.accept(h.req({ orderId: 'o1' }, 'dB')), (e) => e.message === 'CREDIT_INSUFFISANT:50:200');
  assert.equal(wallet(h, 'dB'), 50);
});

test('troisième libération refusée : limite de deux transferts', async () => {
  const h = setup({ extra: { 'livreurs/dC': { wallet: 1000, isOnline: true } } });
  await h.release(h.req({ orderId: 'o1', reason: 'other' })); // transfert 1 (A)
  assignTo(h, 'dB');
  await h.accept(h.req({ orderId: 'o1' }, 'dB'));
  await h.release(h.req({ orderId: 'o1', reason: 'other' }, 'dB')); // transfert 2 (B)
  assert.equal(order(h).transferCount, 2);
  assignTo(h, 'dC');
  await h.accept(h.req({ orderId: 'o1' }, 'dC'));
  await assert.rejects(h.release(h.req({ orderId: 'o1', reason: 'other' }, 'dC')),
    (e) => e.code === 'resource-exhausted');
  assert.equal(order(h).driverId, 'dC');
  assert.equal(wallet(h, 'dC'), 800, 'rien n’est remboursé quand la limite bloque');
  assert.deepEqual([...order(h).excludedDriverIds].sort(), ['dA', 'dB']);
});

test('colis déjà récupéré (picked_up) : refusé, redirigé vers le transfert avec remise', async () => {
  const h = setup({ order: { status: 'picked_up', pickedUpAt: 'ts' } });
  await assert.rejects(h.release(h.req({ orderId: 'o1', reason: 'other' })),
    (e) => e.code === 'failed-precondition' && /remise/.test(e.message));
  assert.equal(order(h).driverId, 'dA');
  assert.equal(wallet(h, 'dA'), 300);
});

test('accepted mais preuve de récupération déjà validée : refusé', async () => {
  const h = setup({ order: { pickupProofValidatedAt: 'ts' } });
  await assert.rejects(h.release(h.req({ orderId: 'o1', reason: 'other' })), (e) => e.code === 'failed-precondition');
  assert.equal(wallet(h, 'dA'), 300);
});

test('course avec avance d’achat (shoppingBudget) : libération automatique suspendue', async () => {
  const h = setup({ order: { shoppingBudget: 5000 } });
  await assert.rejects(h.release(h.req({ orderId: 'o1', reason: 'other' })),
    (e) => e.code === 'failed-precondition' && /SHOPPING_BUDGET_REVIEW/.test(e.message));
  assert.equal(order(h).status, 'accepted');
  assert.equal(wallet(h, 'dA'), 300);
  assert.equal(h.dispatches.length, 0);
});

test('livreur non assigné, motif invalide, anonyme, statuts non libérables : refusés sans effet', async () => {
  const h = setup();
  await assert.rejects(h.release(h.req({ orderId: 'o1', reason: 'other' }, 'dB')), (e) => e.code === 'permission-denied');
  await assert.rejects(h.release(h.req({ orderId: 'o1', reason: 'je-m-ennuie' })), (e) => e.code === 'invalid-argument');
  await assert.rejects(h.release(h.req({ orderId: '../o1', reason: 'other' })), (e) => e.code === 'invalid-argument');
  await assert.rejects(h.release({ auth: null, data: { orderId: 'o1', reason: 'other' } }), (e) => e.code === 'unauthenticated');
  assert.equal(order(h).status, 'accepted');
  for (const status of ['pending', 'assigned', 'delivered', 'cancelled']) {
    const g = setup({ order: { status } });
    await assert.rejects(g.release(g.req({ orderId: 'o1', reason: 'other' })));
    assert.equal(wallet(g, 'dA'), 300);
  }
});

test('commande ancienne sans suivi serveur : remboursement selon la règle historique, une fois', async () => {
  const h = setup();
  const legacy = { ...order(h) };
  delete legacy.commissionStatus; delete legacy.commissionPayerId; delete legacy.commissionAmount;
  h.db.store.set('orders/o1', legacy);
  const result = await h.release(h.req({ orderId: 'o1', reason: 'other' }));
  assert.equal(result.commissionRefunded, 200); // budget 1500 -> 200
  assert.equal(wallet(h, 'dA'), 500);
  assert.equal(order(h).commissionStatus, 'refunded');
});

test('commission déjà remboursée (statut refunded) : aucun remboursement', async () => {
  const h = setup({ order: { commissionStatus: 'refunded' } });
  const result = await h.release(h.req({ orderId: 'o1', reason: 'other' }));
  assert.equal(result.commissionRefunded, 0);
  assert.equal(wallet(h, 'dA'), 300);
});
