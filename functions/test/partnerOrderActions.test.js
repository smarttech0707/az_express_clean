'use strict';

// Mission 7B-3B-P — partnerOrderActionCF : préparation des commandes Restaurant/Boulangerie amountsVersion 2.
// Fonctions RÉELLES (action partenaire, cancelOrderTx, acceptation livreur, annulation client, confirmation de récupération
// QR) sur faux Firestore sérialisé ; données fictives. Les tests de vraie concurrence sont dans
// partnerOrderConcurrency.emulator.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { withSelfie } = require('./selfieHelper');
const { buildPartnerOrderAction } = require('../partnerOrderActions');
const { buildCancelOrder, buildDeliverOrder } = require('../orderActions');
const { buildAcceptOrder } = require('../driverAcceptance');
const { calculateCommission } = require('../dispatch');
const { partnerPickupBlock } = require('../partnerOrderAmounts');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });

const v2 = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'accepted', type: 'restaurant', sellerType: 'restaurant',
  sellerId: 'r1', paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500,
  totalAmount: 4000, budget: 500, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA',
  commissionAmount: 100, ...extra,
});
const legacy = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'accepted', type: 'restaurant', sellerType: 'restaurant',
  sellerId: 'r1', paymentMethod: 'cash', isPaid: false, budget: 700, shoppingBudget: 0, sellerStatus: 'preparing', ...extra,
});

function world(order = v2(), seed = {}, clock = { t: 1000 }) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: 16000, name: 'Aya' },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000, isActive: true },
    'boulangeries/b1': { name: 'Pain Chaud', wallet: 0, isActive: true },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1', isOnline: true },
    ...seed,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission };
  const act = buildPartnerOrderAction({ ...common, onCall: oc, now: () => clock.t }).run;
  const cancel = buildCancelOrder({ ...common, onCall: oc }).run;
  const accept = withSelfie(buildAcceptOrder({ ...common, onCall: oc }).run);
  const deliver = buildDeliverOrder({ ...common, onCall: oc }).run;
  const s = db.store;
  const call = (action, uid = 'r1', extra = {}) => act({ auth: authOf(uid), data: { orderId: 'o1', action, ...extra } });
  return {
    db, s, audits, clock, call,
    accept: () => cancel && accept({ auth: authOf('dA'), data: { orderId: 'o1' } }),
    clientCancel: () => cancel({ auth: authOf('c1'), data: { orderId: 'o1' } }),
    deliver: () => deliver({ auth: authOf('dA'), data: { orderId: 'o1' } }),
    order: () => s.get('orders/o1'),
    w: (p) => s.get(p).wallet,
    refunds: (p) => [...s.keys()].filter((k) => k.startsWith(`${p}/wallet_transactions/`)).map((k) => s.get(k)).filter((x) => x.type === 'refund'),
  };
}

// ── Les quatre actions ────────────────────────────────────────────────────────────────────────────────

test('acceptPartnerOrder : pose partnerAcceptedAtMs seulement — sellerStatus, montants et soldes inchangés', async () => {
  const t = world();
  const r = await t.call('acceptPartnerOrder');
  assert.equal(r.success, true);
  assert.equal(t.order().partnerAcceptedAtMs, 1000);
  assert.equal(t.order().sellerStatus, undefined);
  assert.equal(t.order().preparationStartedAtMs, undefined);
  assert.deepEqual([t.order().productAmount, t.order().totalAmount, t.order().budget, t.order().status], [3500, 4000, 500, 'accepted']);
  assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA'), t.w('restaurants/r1')], [16000, 900, 1000]);
  // Rejeu : aucune réécriture de l'horodatage.
  t.clock.t = 5000;
  const again = await t.call('acceptPartnerOrder');
  assert.equal(again.data.replay, true);
  assert.equal(t.order().partnerAcceptedAtMs, 1000);
});

test('startPreparation (« Accepter et préparer ») : accepte ET démarre en une action ; rejeu idempotent', async () => {
  const t = world(v2({ status: 'pending', driverId: null, commissionStatus: undefined }));
  const r = await t.call('acceptAndPrepare');
  assert.equal(r.success, true);
  assert.deepEqual([t.order().sellerStatus, t.order().preparationStartedAtMs, t.order().partnerAcceptedAtMs], ['preparing', 1000, 1000]);
  t.clock.t = 9000;
  const again = await t.call('startPreparation');
  assert.equal(again.data.replay, true);
  assert.equal(t.order().preparationStartedAtMs, 1000);
  assert.equal(t.audits.filter((a) => a.action === 'partner_order_startPreparation' && !a.status).length, 1, 'un seul journal par transition réelle');
});

test('startPreparation après acceptPartnerOrder conserve l’horodatage d’acceptation', async () => {
  const t = world();
  await t.call('acceptPartnerOrder');
  t.clock.t = 2000;
  await t.call('startPreparation');
  assert.deepEqual([t.order().partnerAcceptedAtMs, t.order().preparationStartedAtMs], [1000, 2000]);
});

test('markReady : seulement depuis preparing ; ni saut d’étape ni retour en arrière', async () => {
  const t = world();
  for (const refused of ['markReady']) {
    const r = await t.call(refused);
    assert.deepEqual([r.success, r.code], [false, 'INVALID_TRANSITION']);
  }
  await t.call('startPreparation');
  t.clock.t = 3000;
  const r = await t.call('markReady');
  assert.equal(r.success, true);
  assert.deepEqual([t.order().sellerStatus, t.order().readyAtMs], ['ready', 3000]);
  assert.equal((await t.call('markReady')).data.replay, true);
  // Retour en arrière : redémarrer la préparation d'une commande prête est refusé, l'état ne bouge pas.
  const back = await t.call('startPreparation');
  assert.deepEqual([back.success, back.code], [false, 'INVALID_TRANSITION']);
  assert.equal(t.order().sellerStatus, 'ready');
  assert.equal(t.order().status, 'accepted', 'aucune action de préparation ne touche au statut de livraison');
});

test('refusePartnerOrder avant préparation (wallet, livreur déjà accepté) : remboursement exact du total, commission rendue, une seule fois', async () => {
  const t = world();
  const r = await t.call('refusePartnerOrder', 'r1', { reason: 'Rupture de stock' });
  assert.equal(r.success, true);
  assert.equal(t.order().status, 'cancelled');
  assert.equal(t.order().cancelReason, 'partner_refused');
  assert.deepEqual(t.order().partnerRefusal, { reason: 'Rupture de stock', partnerId: 'r1', atMs: 1000 });
  assert.equal(t.w('clients/c1'), 16000 + 4000, 'total payé rendu, rien de plus');
  assert.equal(t.w('livreurs/dA'), 900 + 100, 'commission rendue à son payeur');
  assert.equal(t.w('restaurants/r1'), 1000, 'le partenaire n’avait rien reçu');
  assert.equal(t.refunds('clients/c1').length, 1);
  assert.equal(t.refunds('livreurs/dA').length, 1);
  assert.equal(r.data.refund.clientRefund, 4000);
  // Rejeu et appels répétés : aucun second remboursement.
  for (let i = 0; i < 3; i++) assert.equal((await t.call('refusePartnerOrder')).data.replay, true);
  await Promise.allSettled([t.call('refusePartnerOrder'), t.clientCancel()]);
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.w('livreurs/dA'), 1000);
  assert.equal(t.refunds('clients/c1').length, 1);
});

test('refus d’une commande cash non encore acceptée par un livreur : annulée, aucun mouvement de wallet', async () => {
  const t = world(v2({ paymentMethod: 'cash', isPaid: false, status: 'pending', driverId: null, commissionStatus: undefined }));
  const r = await t.call('refusePartnerOrder');
  assert.equal(r.success, true);
  assert.equal(t.order().status, 'cancelled');
  assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA'), t.w('restaurants/r1')], [16000, 900, 1000]);
  assert.equal(t.refunds('clients/c1').length, 0);
});

test('refus impossible une fois la préparation commencée ou la commande prête : aucun remboursement automatique', async () => {
  for (const status of ['preparing', 'ready']) {
    const t = world(v2({ sellerStatus: status }));
    const r = await t.call('refusePartnerOrder');
    assert.deepEqual([r.success, r.code], [false, 'PREPARATION_STARTED']);
    assert.equal(t.order().status, 'accepted');
    assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA')], [16000, 900]);
  }
});

// ── Autorisations ──────────────────────────────────────────────────────────────────────────────────────

test('autorisations : autre partenaire, client, livreur, anonyme, sans compte → refus, aucune écriture', async () => {
  const t = world(v2(), { 'restaurants/r2': { isActive: true }, 'boulangeries/b2': { isActive: true } });
  const before = JSON.stringify(t.order());
  for (const uid of ['r2', 'b2', 'c1', 'dA', 'nobody']) {
    for (const action of ['acceptPartnerOrder', 'startPreparation', 'markReady', 'refusePartnerOrder']) {
      const r = await t.call(action, uid);
      assert.deepEqual([uid, r.success, r.code], [uid, false, 'ORDER_NOT_FOUND']);
    }
  }
  await assert.rejects(() => t.s && require('../partnerOrderActions') && buildPartnerOrderAction({
    db: t.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run({ auth: authOf('r1', 'anonymous'), data: { orderId: 'o1', action: 'markReady' } }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => buildPartnerOrderAction({
    db: t.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run({ data: { orderId: 'o1', action: 'markReady' } }), (e) => e.code === 'unauthenticated');
  assert.equal(JSON.stringify(t.order()), before);
  assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA')], [16000, 900]);
});

test('entrées invalides : action inconnue, orderId absent ou piégé', async () => {
  const t = world();
  await assert.rejects(() => t.call('deleteEverything'), (e) => e.code === 'invalid-argument');
  await assert.rejects(() => t.call('markReady', 'r1', { orderId: '' }), (e) => e.code === 'invalid-argument');
  await assert.rejects(() => t.call('markReady', 'r1', { orderId: 'a/b' }), (e) => e.code === 'invalid-argument');
});

test('partenaire désactivé ou supprimé : refus', async () => {
  const off = world(v2(), { 'restaurants/r1': { isActive: false } });
  assert.equal((await off.call('startPreparation')).code, 'PARTNER_UNAVAILABLE');
  const gone = world(v2(), { 'restaurants/r1': undefined });
  gone.s.delete('restaurants/r1');
  assert.equal((await gone.call('startPreparation')).code, 'PARTNER_UNAVAILABLE');
  assert.equal(off.order().sellerStatus, undefined);
});

test('le partenaire ne peut pas modifier prix, frais ou soldes : champs supplémentaires ignorés', async () => {
  const t = world();
  await t.call('startPreparation', 'r1', { productAmount: 1, totalAmount: 1, deliveryFee: 9, budget: 9, wallet: 99999, sellerStatus: 'ready', status: 'delivered' });
  const o = t.order();
  assert.deepEqual([o.productAmount, o.totalAmount, o.deliveryFee, o.budget, o.status, o.sellerStatus], [3500, 4000, 500, 500, 'accepted', 'preparing']);
  assert.deepEqual([t.w('clients/c1'), t.w('restaurants/r1'), t.w('livreurs/dA')], [16000, 1000, 900]);
});

// ── États terminaux ──────────────────────────────────────────────────────────────────────────────────

test('commande livrée, annulée ou déjà récupérée : toute transition est refusée', async () => {
  for (const [patch, code] of [
    [{ status: 'delivered' }, 'ORDER_CLOSED'],
    [{ status: 'cancelled' }, 'ORDER_CLOSED'],
    [{ status: 'picked_up' }, 'ORDER_PICKED_UP'],
    [{ pickedUpAt: 1 }, 'ORDER_PICKED_UP'],
    [{ status: 'weird' }, 'ORDER_STATUS_INVALID'],
  ]) {
    for (const action of ['acceptPartnerOrder', 'startPreparation', 'markReady', 'refusePartnerOrder']) {
      const t = world(v2({ ...patch, sellerStatus: action === 'markReady' ? 'preparing' : undefined }));
      const r = await t.call(action);
      assert.deepEqual([action, JSON.stringify(patch), r.success, r.code], [action, JSON.stringify(patch), false, code]);
    }
  }
});

// ── Commandes historiques ────────────────────────────────────────────────────────────────────────────

test('commande historique (sans amountsVersion 2) : refusée, rien n’est modifié ; la boulangerie historique garde son flux', async () => {
  const t = world(legacy());
  for (const action of ['acceptPartnerOrder', 'startPreparation', 'markReady', 'refusePartnerOrder']) {
    assert.equal((await t.call(action)).code, 'ORDER_NOT_PARTNER_V2');
  }
  assert.deepEqual([t.order().status, t.order().sellerStatus, t.w('clients/c1')], ['accepted', 'preparing', 16000]);
  // L'annulation client et la livraison historiques restent régies par leurs fonctions existantes.
  const c = world(legacy({ status: 'pending', driverId: null, sellerStatus: undefined }));
  assert.equal((await c.clientCancel()).success, true);
});

test('boulangerie v2 : mêmes transitions (null → preparing → ready), compatibles avec les états de l’écran actuel', async () => {
  const t = world(v2({ type: 'boulangerie', sellerType: 'boulangerie', sellerId: 'b1', sellerStatus: null, itemsAmount: 3500 }));
  assert.equal((await t.call('acceptPartnerOrder', 'b1')).success, true);
  assert.equal(t.order().sellerStatus, null, 'acceptation sans nouvel état inconnu de l’écran boulangerie');
  assert.equal((await t.call('startPreparation', 'b1')).success, true);
  assert.equal(t.order().sellerStatus, 'preparing');
  assert.equal((await t.call('markReady', 'b1')).success, true);
  assert.equal(t.order().sellerStatus, 'ready');
});

// ── Concurrence (faux Firestore sérialisé) ─────────────────────────────────────────────────────────────

test('préparation et annulation client simultanées : soit remboursé intégralement, soit annulation refusée — jamais les deux', async () => {
  for (let i = 0; i < 8; i++) {
    const t = world();
    const calls = i % 2 ? [t.clientCancel(), t.call('startPreparation')] : [t.call('startPreparation'), t.clientCancel()];
    await Promise.allSettled(calls);
    const o = t.order();
    if (o.status === 'cancelled') {
      assert.equal(o.sellerStatus, undefined, 'annulée avant tout démarrage de préparation');
      assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA')], [20000, 1000]);
    } else {
      assert.equal(o.sellerStatus, 'preparing');
      assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA')], [16000, 900]);
    }
  }
});

test('refus et acceptation du livreur simultanés : cohérence des soldes dans les deux ordres', async () => {
  for (let i = 0; i < 6; i++) {
    const t = world(v2({ status: 'assigned', commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined }), {
      'livreurs/dA': { wallet: 900, isOnline: true, isAvailable: true },
    });
    const calls = i % 2 ? [t.accept(), t.call('refusePartnerOrder')] : [t.call('refusePartnerOrder'), t.accept()];
    await Promise.allSettled(calls);
    const o = t.order();
    assert.ok(['cancelled', 'accepted'].includes(o.status), `tour ${i} : ${o.status}`);
    if (o.status === 'cancelled') {
      // Soit refusée avant l'acceptation (commission jamais prélevée), soit après (commission prélevée puis rendue) :
      // dans les deux cas le livreur retrouve son solde initial et le client est remboursé du total, une fois.
      assert.equal(t.w('clients/c1'), 20000);
      assert.equal(t.w('livreurs/dA'), 900);
      assert.equal(t.refunds('clients/c1').length, 1);
    } else {
      // Acceptation passée avant le refus : le refus est alors un échec propre ou n'a pas eu lieu — état cohérent.
      assert.deepEqual([t.w('clients/c1'), t.w('livreurs/dA')], [16000, 800]);
    }
  }
});

test('plusieurs refus et rejeux simultanés : un seul remboursement', async () => {
  const t = world();
  await Promise.allSettled(Array.from({ length: 6 }, () => t.call('refusePartnerOrder')));
  assert.equal(t.w('clients/c1'), 20000);
  assert.equal(t.w('livreurs/dA'), 1000);
  assert.equal(t.refunds('clients/c1').length, 1);
  assert.equal(t.audits.filter((a) => a.action === 'partner_order_refusePartnerOrder' && !a.status).length, 1);
});

// ── Récupération : aucune transition de préparation ne contourne le contrôle serveur ──────────────────────

test('récupération : bloquée tant que la commande n’est pas prête, quelle que soit la séquence d’actions', async () => {
  const t = world(v2({ status: 'accepted' }));
  assert.equal(partnerPickupBlock(t.order()).code, 'failed-precondition');
  await t.call('acceptPartnerOrder');
  assert.ok(partnerPickupBlock(t.order()), 'accepter ne rend pas la commande récupérable');
  await t.call('startPreparation');
  assert.ok(partnerPickupBlock(t.order()), 'préparer ne rend pas la commande récupérable');
  assert.equal((await t.call('markReady')).success, true);
  assert.equal(partnerPickupBlock(t.order()), null, 'prête : récupération permise (QR/PIN et statut vérifiés ailleurs)');
  // Aucune action de préparation n'a pu écrire picked_up.
  assert.equal(t.order().status, 'accepted');
});
