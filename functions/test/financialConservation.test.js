'use strict';

// Conservation des montants, de bout en bout, avec les VRAIES fonctions
// (acceptOrderCF, releaseOrderBeforePickupCF, deliveryTransferCF, deliverOrderCF,
// settleTransferEarningsCF, cancelOrderCF) sur un faux Firestore.
//
// Invariant vérifié pour chaque scénario (prix 1000 FCFA, commission 200) :
//   sortie du client = gains nets des livreurs + commission AZ
// où gain net d'un livreur = variation de son wallet + espèces qu'il détient
// − espèces qu'il doit à un autre livreur. Aucun FCFA créé ni perdu.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildAcceptOrder } = require('../driverAcceptance');
const { withSelfie } = require('./selfieHelper');
const { buildReleaseOrderBeforePickup } = require('../driverRelease');
const { buildDeliveryTransfer } = require('../driverTransfer');
const { buildDeliverOrder, buildCancelOrder } = require('../orderActions');
const { buildSettleTransferEarnings } = require('../transferSettlement');
const { calculateCommission, DispatchError } = require('../dispatch');

process.env.DELIVERY_PROOFS_ENABLED = 'true';
process.env.DELIVERY_PROOF_PEPPER = 'test-pepper';

const ts = (ms) => ({ toMillis: () => ms });
const admin = {
  firestore: {
    Timestamp: { fromMillis: ts },
    FieldValue: {
      serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion,
      increment: (n) => ({ __increment: n }),
    },
  },
};
const PRICE = 1000;
const COMMISSION = 200;
const fresh = () => ({ toMillis: () => Date.now() - 1000 });
const driver = (extra = {}) => ({
  wallet: 1000, isOnline: true, isAvailable: true, currentCityId: 'abengourou',
  lat: 6.74, lng: -3.49, updatedAt: fresh(), ...extra,
});

function world({ method = 'wallet', orderExtra = {} } = {}) {
  const wallet = method === 'wallet';
  const db = fakeDb({
    'orders/o1': {
      clientId: 'c1', status: 'assigned', driverId: 'dA', budget: PRICE, description: 'Course',
      paymentMethod: method, isPaid: wallet, pickupCityId: 'abengourou',
      latitude: 6.70, longitude: -3.49, destLat: 6.80, destLng: -3.49, ...orderExtra,
    },
    // Le client a déjà payé 1000 à la création (wallet) : 5000 -> 4000.
    'clients/c1': { wallet: wallet ? 4000 : 5000 },
    'livreurs/dA': driver(),
    'livreurs/dB': driver({ lat: 6.7401 }),
    'admins/root': { role: 'super', isActive: true },
  });
  const oc = (...a) => ({ run: a[a.length - 1] });
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const fns = {
    accept: withSelfie(buildAcceptOrder({ ...common, onCall: oc, calculateCommission }).run),
    release: buildReleaseOrderBeforePickup({ ...common, onCall: oc, calculateCommission,
      dispatchOrder: async () => ({ dispatched: false }), DispatchError }).run,
    transfer: buildDeliveryTransfer({ ...common, onCall: (...a) => ({ run: a[a.length - 1] }) }).run,
    deliver: buildDeliverOrder({ ...common, onCall: oc }).run,
    cancel: buildCancelOrder({ ...common, onCall: oc, calculateCommission }).run,
    settle: buildSettleTransferEarnings({ ...common, onCall: oc,
      requireSuperAdmin: async ({ request }) => {
        if (request.auth.uid !== 'root') throw new HttpsError('permission-denied', 'non');
      } }).run,
  };
  const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  const call = (name, uid, data) => fns[name](req(uid, data));
  const w = (id) => db.store.get(`${id.startsWith('c') ? 'clients' : 'livreurs'}/${id}`).wallet;
  const get = (p) => db.store.get(p);
  const commissionLogged = () => [...db.store.entries()]
    .filter(([k]) => k.startsWith('commissions/')).reduce((s, [, v]) => s + v.amount, 0);
  return { db, call, w, get, commissionLogged };
}

async function transferToB(h) {
  await h.call('accept', 'dA', { orderId: 'o1' });
  h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up', pickedUpAt: 1 });
  const r = await h.call('transfer', 'dA', { action: 'request', orderId: 'o1', reason: 'vehicle_problem' });
  await h.call('transfer', 'dB', { action: 'accept', transferId: r.transferId });
  const p = await h.call('transfer', 'dB', { action: 'prepareHandover', transferId: r.transferId });
  await h.call('transfer', 'dA', { action: 'confirmHandover', transferId: r.transferId, token: p.token });
}

const close = (a, b) => Math.abs(a - b) <= 1;

// ---------------------------------------------------------------- 1
test('1. livraison ordinaire wallet : A +800 net, AZ 200, client −1000', async () => {
  const h = world();
  await h.call('accept', 'dA', { orderId: 'o1' });
  assert.equal(h.w('dA'), 800); // commission prélevée une fois
  h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up' });
  await h.call('deliver', 'dA', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  assert.equal(h.w('dA'), 1800); // pool 1000 crédité
  const net = h.w('dA') - 1000;
  const clientOut = 5000 - h.w('c1');
  assert.equal(net, 800);
  assert.equal(h.commissionLogged(), COMMISSION);
  assert.equal(clientOut, net + h.commissionLogged());
  assert.equal(h.get('transfer_settlements/o1'), undefined);
  assert.equal(h.get('config/az_wallet').totalCommissions, COMMISSION);
});

// ---------------------------------------------------------------- 2
test('2. livraison transférée wallet : A 320 net, B 480 net, AZ 200, somme exacte', async () => {
  const h = world();
  await transferToB(h);
  assert.equal(h.get('orders/o1').driverId, 'dB');
  await h.call('deliver', 'dB', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  // Avant validation : rien n’est crédité, la retenue est en place.
  assert.equal(h.w('dA'), 800);
  assert.equal(h.w('dB'), 1000);
  assert.equal(h.get('orders/o1').settlementHold, true);
  assert.equal(h.commissionLogged(), COMMISSION); // une seule commission journalisée
  const s = h.get('transfer_settlements/o1');
  assert.equal(s.proposal.needsReview, false);
  await h.call('settle', 'root', { action: 'approve', orderId: 'o1' });
  const netA = h.w('dA') - 1000;
  const netB = h.w('dB') - 1000;
  assert.ok(close(netA, 320) && close(netB, 480), `A=${netA} B=${netB}`);
  assert.equal(netA + netB, 800);
  assert.equal(5000 - h.w('c1'), netA + netB + h.commissionLogged());
  assert.equal(h.get('orders/o1').settlementHold, false);
  // Rejeu de la validation : aucun mouvement supplémentaire.
  const before = [h.w('dA'), h.w('dB')];
  assert.equal((await h.call('settle', 'root', { action: 'approve', orderId: 'o1' })).replay, true);
  assert.deepEqual([h.w('dA'), h.w('dB')], before);
  // Le montant AZ n’a jamais été crédité à un livreur.
  assert.equal(h.get('config/az_wallet').totalCommissions, COMMISSION);
});

// ---------------------------------------------------------------- 3
test('3. livraison ordinaire cash : wallet A −200, espèces 1000 détenues, net 800', async () => {
  const h = world({ method: 'cash' });
  await h.call('accept', 'dA', { orderId: 'o1' });
  h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up' });
  await h.call('deliver', 'dA', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  assert.equal(h.w('dA'), 800);
  const cashHeldByA = PRICE; // le client a payé 1000 en espèces à A
  const netA = (h.w('dA') - 1000) + cashHeldByA;
  assert.equal(netA, 800);
  assert.equal(PRICE, netA + h.commissionLogged());
  assert.equal(h.w('c1'), 5000); // aucun wallet client touché
});

// ---------------------------------------------------------------- 4
test('4. livraison transférée cash : B détient 1000, doit 520 à A ; A 320 net, B 480 net, AZ 200', async () => {
  const h = world({ method: 'cash' });
  await transferToB(h);
  await h.call('deliver', 'dB', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  assert.deepEqual([h.w('dA'), h.w('dB'), h.w('c1')], [800, 1000, 5000]); // aucun wallet touché
  const r = await h.call('settle', 'root', { action: 'approve', orderId: 'o1' });
  assert.equal(r.status, 'cash_pending');
  assert.deepEqual([h.w('dA'), h.w('dB')], [800, 1000]); // toujours aucun mouvement de wallet
  const owed = r.toRegularize[0];
  assert.deepEqual([owed.from, owed.to], ['dB', 'dA']);
  const cashB = PRICE - owed.amount;
  const cashA = owed.amount;
  const netA = (h.w('dA') - 1000) + cashA;
  const netB = (h.w('dB') - 1000) + cashB;
  assert.ok(close(netA, 320) && close(netB, 480), `A=${netA} B=${netB}`);
  assert.equal(PRICE, netA + netB + h.commissionLogged());
  await h.call('settle', 'dA', { action: 'confirmCashReceipt', orderId: 'o1' });
  await h.call('settle', 'root', { action: 'closeCash', orderId: 'o1' });
  assert.deepEqual([h.w('dA'), h.w('dB')], [800, 1000]); // jamais de débit automatique
  assert.equal(h.get('orders/o1').settlementHold, false);
});

// ---------------------------------------------------------------- 5
test('5. annulation avant récupération : A remboursé de sa commission, client remboursé, AZ 0', async () => {
  const h = world();
  await h.call('accept', 'dA', { orderId: 'o1' });
  assert.equal(h.w('dA'), 800);
  await h.call('release', 'dA', { orderId: 'o1', reason: 'vehicle_problem' });
  assert.equal(h.w('dA'), 1000); // restitution exacte, une seule fois
  assert.equal(h.get('orders/o1').commissionStatus, 'refunded');
  // rejeu de la libération : aucun second remboursement
  await h.call('release', 'dA', { orderId: 'o1', reason: 'vehicle_problem' });
  assert.equal(h.w('dA'), 1000);
  // puis annulation par le client (course remise en file)
  await h.call('cancel', 'c1', { orderId: 'o1' });
  assert.equal(h.w('c1'), 5000);
  assert.equal(h.w('dA'), 1000); // pas de second remboursement de commission
  assert.equal(h.commissionLogged(), 0);
});

// ---------------------------------------------------------------- 6
test('6. annulation après transfert : commission rendue à A (payeur), client remboursé, B et AZ à 0', async () => {
  const h = world();
  await transferToB(h);
  assert.equal(h.w('dA'), 800);
  await h.call('cancel', 'c1', { orderId: 'o1' });
  assert.equal(h.w('c1'), 5000);
  assert.equal(h.w('dA'), 1000); // payeur d’origine
  assert.equal(h.w('dB'), 1000); // B n’a rien payé, rien reçu
  assert.equal(h.get('orders/o1').commissionStatus, 'refunded');
  assert.equal(h.get('livreurs/dB').isOnDelivery, false);
  assert.equal(h.commissionLogged(), 0);
  // rejeu : aucun double remboursement (la commande est déjà annulée)
  await assert.rejects(h.call('cancel', 'c1', { orderId: 'o1' }));
  assert.equal(h.w('dA'), 1000);
  assert.equal(h.w('c1'), 5000);
});

// ---------------------------------------------------------------- extras
test('commission 100 sous 1000 FCFA : journal et remboursement suivent le montant réellement prélevé', async () => {
  const h = world({ orderExtra: { budget: 800 } });
  await h.call('accept', 'dA', { orderId: 'o1' });
  assert.equal(h.w('dA'), 900);
  h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up' });
  await h.call('deliver', 'dA', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  assert.equal(h.commissionLogged(), 100);
  assert.equal(h.get('config/az_wallet').totalCommissions, 100);
});

test('course acceptée avant le suivi serveur (sans trace) : journal au barème à paliers, pas 100 fixe', async () => {
  const h = world({ orderExtra: { status: 'picked_up', driverId: 'dA', budget: 1500 } });
  await h.call('deliver', 'dA', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  const entry = [...h.db.store.entries()].find(([k]) => k.startsWith('commissions/'))[1];
  assert.equal(entry.amount, 200);
  assert.equal(entry.commissionSource, 'legacy_tiered');
});

test('commande wallet explicitement non payée annulée : aucun remboursement fictif au client', async () => {
  const h = world({ orderExtra: { status: 'pending', driverId: null, isPaid: false } });
  const before = h.w('c1');
  await h.call('cancel', 'c1', { orderId: 'o1' });
  assert.equal(h.w('c1'), before);
});

test('GPS de remise absent : le gain reste retenu, aucune part inventée, rien n’est crédité', async () => {
  const h = world();
  h.db.store.set('livreurs/dA', driver({ updatedAt: { toMillis: () => Date.now() - 3600_000 } }));
  await transferToB(h);
  await h.call('deliver', 'dB', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  const s = h.get('transfer_settlements/o1');
  assert.equal(s.proposal.credits, null);
  await assert.rejects(h.call('settle', 'root', { action: 'approve', orderId: 'o1' }), /Données insuffisantes/);
  assert.equal(h.w('dA'), 800);
  assert.equal(h.w('dB'), 1000);
  // correction justifiée : la somme doit rester égale au prix payé
  await h.call('settle', 'root', { action: 'approve', orderId: 'o1', credits: { dA: 520, dB: 480 },
    justification: 'Positions confirmées par téléphone avec les deux livreurs' });
  assert.equal((h.w('dA') - 1000) + (h.w('dB') - 1000), 800);
});

// ------------------------------------------------- annulation pendant un transfert
async function reserveB(h) {
  await h.call('accept', 'dA', { orderId: 'o1' });
  h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up', pickedUpAt: 1 });
  const r = await h.call('transfer', 'dA', { action: 'request', orderId: 'o1', reason: 'vehicle_problem' });
  await h.call('transfer', 'dB', { action: 'accept', transferId: r.transferId });
  const p = await h.call('transfer', 'dB', { action: 'prepareHandover', transferId: r.transferId });
  return { id: r.transferId, p };
}

test('annulation pendant un transfert (B réservé) : B libéré, transfert annulé, preuve révoquée, un seul remboursement', async () => {
  const h = world();
  const { id, p } = await reserveB(h);
  assert.equal(h.get('livreurs/dB').isOnDelivery, true);
  await h.call('cancel', 'c1', { orderId: 'o1' });
  // B immédiatement disponible
  assert.equal(h.get('livreurs/dB').isOnDelivery, false);
  assert.equal(h.get('livreurs/dB').pendingOrderId, undefined);
  // transfert annulé, historique conservé
  const t = h.get(`delivery_transfers/${id}`);
  assert.deepEqual([t.status, t.closeReason, t.fromDriverId, t.toDriverId], ['cancelled', 'order_cancelled', 'dA', 'dB']);
  assert.equal(h.get('orders/o1').activeTransferId, undefined);
  assert.equal(h.get('orders/o1').status, 'cancelled');
  // aucune preuve utilisable
  const proofs = [...h.db.store.entries()].filter(([k]) => k.includes('/versions/'));
  assert.ok(proofs.length > 0 && proofs.every(([, v]) => v.status !== 'active'));
  await assert.rejects(h.call('transfer', 'dA', { action: 'confirmHandover', transferId: id, token: p.token }));
  await assert.rejects(h.call('transfer', 'dA', { action: 'confirmHandover', transferId: id, pin: p.pin }));
  await assert.rejects(h.call('transfer', 'dB', { action: 'prepareHandover', transferId: id }));
  await assert.rejects(h.call('transfer', 'dB', { action: 'accept', transferId: id }));
  // argent : client remboursé une fois, commission rendue à A une fois, B et AZ à 0
  assert.equal(h.w('c1'), 5000);
  assert.equal(h.w('dA'), 1000);
  assert.equal(h.w('dB'), 1000);
  assert.equal(h.get('orders/o1').driverId, 'dA'); // A reste le dernier responsable inscrit
  // rejeu : refusé, aucun second remboursement ni crédit
  await assert.rejects(h.call('cancel', 'c1', { orderId: 'o1' }));
  assert.equal(h.w('c1'), 5000);
  assert.equal(h.w('dA'), 1000);
  assert.equal(h.commissionLogged(), 0);
  assert.equal(h.get('transfer_settlements/o1'), undefined);
});

test('annulation pendant une demande non encore acceptée : transfert annulé, aucun livreur réservé', async () => {
  const h = world();
  await h.call('accept', 'dA', { orderId: 'o1' });
  h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up', pickedUpAt: 1 });
  const r = await h.call('transfer', 'dA', { action: 'request', orderId: 'o1', reason: 'other' });
  await h.call('cancel', 'c1', { orderId: 'o1' });
  assert.equal(h.get(`delivery_transfers/${r.transferId}`).status, 'cancelled');
  assert.equal(h.get('orders/o1').activeTransferId, undefined);
  await assert.rejects(h.call('transfer', 'dB', { action: 'accept', transferId: r.transferId }));
  assert.equal(h.get('livreurs/dB').isOnDelivery, undefined);
  assert.equal(h.w('dA'), 1000);
});

test('annulation cash pendant un transfert : aucun mouvement de wallet client, commission rendue à A', async () => {
  const h = world({ method: 'cash' });
  await reserveB(h);
  await h.call('cancel', 'c1', { orderId: 'o1' });
  assert.deepEqual([h.w('c1'), h.w('dA'), h.w('dB')], [5000, 1000, 1000]);
  assert.equal(h.get('livreurs/dB').isOnDelivery, false);
});

// ------------------------------------------------- commandes marketplace / partenaire
test('transfert refusé sur une commande marketplace ou boutique : le budget est l’argent du produit, pas un gain de livraison', async () => {
  for (const sellerType of ['seller', 'boutique']) {
    const h = world({ orderExtra: { sellerId: 's1', sellerType } });
    h.db.store.set('config/billing', { legacyPartnerAcceptance: 'no_commission' });
    await h.call('accept', 'dA', { orderId: 'o1' });
    h.db.store.set('orders/o1', { ...h.get('orders/o1'), status: 'picked_up', pickedUpAt: 1 });
    await assert.rejects(
      h.call('transfer', 'dA', { action: 'request', orderId: 'o1', reason: 'other' }), /PARTNER_ORDER_REVIEW/);
    assert.equal(h.get('orders/o1').activeTransferId, undefined);
  }
});

test('commande partenaire (restaurant) transférée en cash : aucune part automatique, validation administrative obligatoire', async () => {
  const h = world({ method: 'cash', orderExtra: { sellerId: 'r1', sellerType: 'restaurant' } });
  await transferToB(h);
  await h.call('deliver', 'dB', { orderId: 'o1', deliveryPhotoUrl: 'https://x/p.jpg' });
  const s = h.get('transfer_settlements/o1');
  assert.equal(s.proposal.credits, null);
  assert.ok(s.proposal.reasons.includes('partner_order_amount_semantics'));
  await assert.rejects(h.call('settle', 'root', { action: 'approve', orderId: 'o1' }), /Données insuffisantes/);
  assert.deepEqual([h.w('dA'), h.w('dB')], [800, 1000]);
});
