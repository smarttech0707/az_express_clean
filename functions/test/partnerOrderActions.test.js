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
const { requireSuperAdmin } = require('../adminGuards');
const { analyzePartnerOrders } = require('../partnerOrderReconciliation');

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

function world(order = v2(), seed = {}, clock = { t: 1000 }, flags = { enabled: true }) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: 16000, name: 'Aya' },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000, isActive: true },
    'boulangeries/b1': { name: 'Pain Chaud', wallet: 0, isActive: true },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1', isOnline: true },
    'livreurs/dOld': { wallet: 500, isOnline: true },
    'admins/root': { role: 'super', isActive: true },
    'admins/sub': { role: 'sub', isActive: true, permissions: ['commandes'] },
    ...seed,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission };
  const act = buildPartnerOrderAction({ ...common, onCall: oc, requireSuperAdmin, now: () => clock.t, isEnabled: () => flags.enabled }).run;
  const cancel = buildCancelOrder({ ...common, onCall: oc }).run;
  const accept = withSelfie(buildAcceptOrder({ ...common, onCall: oc }).run);
  const deliver = buildDeliverOrder({ ...common, onCall: oc }).run;
  const s = db.store;
  const call = (action, uid = 'r1', extra = {}) => act({ auth: authOf(uid), data: { orderId: 'o1', action, ...extra } });
  return {
    db, s, audits, clock, flags, call,
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

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// Mission 7B-3B-C — reversement cash
// ════════════════════════════════════════════════════════════════════════════════════════════════════

const REQ_A = 'resolve-request-0001';
const REQ_B = 'resolve-request-0002';
const JUST = 'Désaccord tranché après appel des deux parties';
const cash = (extra = {}, r = {}) => v2({
  status: 'delivered', paymentMethod: 'cash', isPaid: false, merchantCashSettled: false,
  cashRemittance: {
    status: 'pending', orderId: 'o1', partnerId: 'r1', sellerType: 'restaurant', driverId: 'dA', amountDue: 3500,
    amountHandedOver: null, deliveredAtMs: 1, handedOverAtMs: null, partnerConfirmedAtMs: null, ...r,
  },
  ...extra,
});
const cw = (extra, r) => world(cash(extra, r), { 'restaurants/r2': { isActive: true } });
const declare = (t, amount, uid = 'dA') => t.call('declareCashHandover', uid, { amount });
const confirm = (t, amount, uid = 'r1') => t.call('confirmCashRemittance', uid, { amount });
const dispute = (t, uid, reason = 'Le montant remis ne correspond pas à ma recette') => t.call('disputeCashRemittance', uid, { reason });
const resolve = (t, over = {}, uid = 'root') => t.call('resolveCashRemittance', uid, { requestId: REQ_A, justification: JUST, finalAmount: 3500, ...over });
const walletTxKeys = (t) => [...t.s.keys()].filter((k) => k.includes('/wallet_transactions/'));
const balances = (t) => [t.w('clients/c1'), t.w('livreurs/dA'), t.w('restaurants/r1')];
const findingsOf = (t, nowMs = 10 * 24 * 3600 * 1000) => {
  const r = analyzePartnerOrders({ orders: [{ id: 'o1', ...t.order() }], nowMs });
  return (r.rows.find((x) => x.orderId === 'o1' || x.id === 'o1')?.findings || []).map((f) => f.code);
};

test('interrupteur PARTNER_ORDERS_V2 désactivé : toutes les actions (préparation, cash, résolution) refusées sans aucun effet', async () => {
  const t = cw();
  t.flags.enabled = false;
  const before = JSON.stringify(t.order());
  const all = [
    ['acceptPartnerOrder', 'r1', {}], ['startPreparation', 'r1', {}], ['acceptAndPrepare', 'r1', {}], ['markReady', 'r1', {}],
    ['refusePartnerOrder', 'r1', {}], ['declareCashHandover', 'dA', { amount: 3500 }], ['confirmCashRemittance', 'r1', { amount: 3500 }],
    ['disputeCashRemittance', 'r1', { reason: 'Désaccord sur le montant' }],
    ['resolveCashRemittance', 'root', { requestId: REQ_A, justification: JUST, finalAmount: 0 }],
  ];
  for (const [action, uid, extra] of all) {
    const r = await t.call(action, uid, extra);
    assert.deepEqual([action, r.success, r.code], [action, false, 'FEATURE_DISABLED']);
  }
  assert.equal(JSON.stringify(t.order()), before);
  // Réactivé : la même demande aboutit (preuve que le refus venait bien de l'interrupteur).
  t.flags.enabled = true;
  assert.equal((await declare(t, 3500)).success, true);
});

test('interrupteur désactivé : l\'authentification reste exigée avant tout (anonyme rejeté)', async () => {
  const t = cw();
  t.flags.enabled = false;
  const fn = buildPartnerOrderAction({
    db: t.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, isEnabled: () => false,
  }).run;
  await assert.rejects(() => fn({ auth: authOf('r1', 'anonymous'), data: { orderId: 'o1', action: 'markReady' } }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => fn({ data: { orderId: 'o1', action: 'markReady' } }), (e) => e.code === 'unauthenticated');
});

test('interrupteur par défaut : désactivé sans PARTNER_ORDERS_V2=on', async () => {
  const previous = process.env.PARTNER_ORDERS_V2;
  try {
    delete process.env.PARTNER_ORDERS_V2;
    const t = cw();
    const fn = buildPartnerOrderAction({
      db: t.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
    }).run;
    assert.equal((await fn({ auth: authOf('dA'), data: { orderId: 'o1', action: 'declareCashHandover', amount: 3500 } })).code, 'FEATURE_DISABLED');
    process.env.PARTNER_ORDERS_V2 = 'off';
    assert.equal((await fn({ auth: authOf('dA'), data: { orderId: 'o1', action: 'declareCashHandover', amount: 3500 } })).code, 'FEATURE_DISABLED');
    assert.equal(t.order().cashRemittance.status, 'pending');
  } finally {
    if (previous === undefined) delete process.env.PARTNER_ORDERS_V2; else process.env.PARTNER_ORDERS_V2 = previous;
  }
});

test('declareCashHandover : livreur final seulement ; déclaration ≠ confirmation ; rien n\'est réglé ; aucun wallet', async () => {
  const t = cw();
  const before = balances(t);
  const r = await declare(t, 3500);
  assert.equal(r.success, true);
  const c = t.order().cashRemittance;
  assert.deepEqual([c.status, c.amountHandedOver, c.handedOverAtMs, c.handedOverBy], ['declared', 3500, 1000, 'dA']);
  assert.equal(c.partnerConfirmedAtMs, null);
  assert.equal(c.amountConfirmed, undefined);
  assert.equal(t.order().merchantCashSettled, false, 'une déclaration du livreur ne règle JAMAIS le partenaire');
  assert.equal(r.data.cash.merchantCashSettled, false);
  assert.deepEqual(balances(t), before);
  assert.equal(walletTxKeys(t).length, 0);
  // Rejeu strict : rien ne change, y compris l'horodatage.
  t.clock.t = 7000;
  const again = await declare(t, 3500);
  assert.equal(again.data.replay, true);
  assert.equal(t.order().cashRemittance.handedOverAtMs, 1000);
  // Correction avant confirmation : permise.
  assert.equal((await declare(t, 3000)).success, true);
  assert.equal(t.order().cashRemittance.amountHandedOver, 3000);
});

test('declareCashHandover : refusé au partenaire, à un ancien livreur, au client, à l\'admin et aux inconnus', async () => {
  const t = cw();
  const before = JSON.stringify(t.order());
  for (const uid of ['r1', 'r2', 'dOld', 'c1', 'root', 'nobody']) {
    const r = await declare(t, 3500, uid);
    assert.deepEqual([uid, r.success, r.code], [uid, false, 'ORDER_NOT_FOUND']);
  }
  assert.equal(JSON.stringify(t.order()), before);
});

test('montants invalides refusés : nul, négatif, décimal, texte, NaN, excessif', async () => {
  const t = cw();
  for (const amount of [0, -5, 1.5, '3500', NaN, null, undefined, 3501, 10 ** 12]) {
    const d = await declare(t, amount);
    const c = await confirm(t, amount);
    assert.equal(d.success, false, `declare ${String(amount)}`);
    assert.equal(c.success, false, `confirm ${String(amount)}`);
    assert.ok(['INVALID_AMOUNT', 'AMOUNT_EXCEEDS_DUE'].includes(d.code) && ['INVALID_AMOUNT', 'AMOUNT_EXCEEDS_DUE'].includes(c.code));
  }
  assert.equal(t.order().cashRemittance.status, 'pending');
});

test('confirmCashRemittance intégrale : réglé UNE fois, rejeu inoffensif, plus aucune action possible', async () => {
  const t = cw();
  await declare(t, 3500);
  const before = balances(t);
  const r = await confirm(t, 3500);
  assert.equal(r.success, true);
  const o = t.order();
  assert.deepEqual([o.cashRemittance.status, o.cashRemittance.amountConfirmed, o.cashRemittance.outstanding, o.merchantCashSettled],
    ['confirmed', 3500, 0, true]);
  assert.deepEqual([o.cashRemittance.confirmedBy, o.cashRemittance.partnerConfirmedAtMs, o.cashRemittance.settledAtMs], ['r1', 1000, 1000]);
  assert.deepEqual(balances(t), before);
  assert.equal(walletTxKeys(t).length, 0);
  t.clock.t = 9000;
  assert.equal((await confirm(t, 3500)).data.replay, true);
  assert.equal(t.order().cashRemittance.partnerConfirmedAtMs, 1000);
  for (const [res, code] of [[await confirm(t, 3000), 'CASH_ALREADY_FINAL'], [await declare(t, 3500), 'CASH_ALREADY_FINAL'],
    [await dispute(t, 'r1'), 'CASH_ALREADY_FINAL'], [await dispute(t, 'dA'), 'CASH_ALREADY_FINAL'], [await resolve(t), 'CASH_ALREADY_FINAL']]) {
    assert.deepEqual([res.success, res.code], [false, code]);
  }
  assert.deepEqual(findingsOf(t), [], 'rapprochement A2 : reversement confirmé en totalité, aucun constat');
});

test('seul le partenaire propriétaire confirme ; jamais le livreur, un autre partenaire ou le client', async () => {
  const t = cw();
  await declare(t, 3500);
  for (const uid of ['dA', 'r2', 'c1', 'dOld', 'root']) {
    assert.deepEqual([uid, (await confirm(t, 3500, uid)).code], [uid, 'ORDER_NOT_FOUND']);
  }
  assert.equal(t.order().cashRemittance.status, 'declared');
  assert.equal(t.order().merchantCashSettled, false);
  // Le partenaire peut confirmer même sans déclaration préalable du livreur (il est l'autorité sur ce qu'il reçoit).
  const t2 = cw();
  assert.equal((await confirm(t2, 3500)).success, true);
});

test('confirmation partielle : reliquat conservé, jamais réglé ; suite déclarée puis confirmée ; aucun débit automatique', async () => {
  const t = cw();
  const before = balances(t);
  await declare(t, 2000);
  const part = await confirm(t, 2000);
  assert.equal(part.data.cash.outstanding, 1500);
  let o = t.order();
  assert.deepEqual([o.cashRemittance.status, o.cashRemittance.outstanding, o.merchantCashSettled], ['confirmed', 1500, false]);
  assert.deepEqual(findingsOf(t), ['V2_CASH_SHORTFALL'], 'A2 voit le reliquat, pas de constat de règlement');
  // Moins que déjà confirmé, ou plus que dû : refusé.
  assert.equal((await confirm(t, 1000)).code, 'INVALID_AMOUNT');
  assert.equal((await confirm(t, 3501)).code, 'AMOUNT_EXCEEDS_DUE');
  // Le livreur ne peut pas re-déclarer moins que ce qui est déjà confirmé.
  assert.equal((await declare(t, 2000)).code, 'INVALID_AMOUNT');
  assert.equal((await declare(t, 3500)).success, true);
  o = t.order();
  assert.deepEqual([o.cashRemittance.status, o.cashRemittance.amountConfirmed, o.merchantCashSettled], ['declared', 2000, false]);
  assert.equal((await confirm(t, 3500)).success, true);
  o = t.order();
  assert.deepEqual([o.cashRemittance.status, o.cashRemittance.outstanding, o.merchantCashSettled], ['confirmed', 0, true]);
  assert.deepEqual(balances(t), before);
  assert.equal(walletTxKeys(t).length, 0);
});

test('disputeCashRemittance : partenaire ou livreur final, motif obligatoire ; gèle déclaration et confirmation', async () => {
  const t = cw();
  assert.equal((await dispute(t, 'r1', 'court')).code, 'REASON_REQUIRED');
  assert.equal((await dispute(t, 'r1', 'x'.repeat(301))).code, 'REASON_REQUIRED');
  for (const uid of ['r2', 'dOld', 'c1', 'root', 'nobody']) assert.equal((await dispute(t, uid)).code, 'ORDER_NOT_FOUND', uid);
  const r = await dispute(t, 'dA', 'Le partenaire refuse de signer la réception');
  assert.equal(r.success, true);
  const c = t.order().cashRemittance;
  assert.deepEqual([c.status, c.dispute.byUid, c.dispute.byRole, c.dispute.previousStatus], ['disputed', 'dA', 'driver', 'pending']);
  assert.equal(t.order().merchantCashSettled, false);
  assert.equal((await dispute(t, 'r1')).data.replay, true, 'déjà contesté : pas d\'écrasement');
  assert.equal(t.order().cashRemittance.dispute.byUid, 'dA');
  assert.equal((await declare(t, 3500)).code, 'CASH_DISPUTED');
  assert.equal((await confirm(t, 3500)).code, 'CASH_DISPUTED');
  assert.deepEqual(findingsOf(t), ['V2_CASH_DISPUTED']);
  const p = cw();
  await dispute(p, 'r1');
  assert.equal(p.order().cashRemittance.dispute.byRole, 'partner');
});

test('resolveCashRemittance : super-administrateur seul, requestId et justification obligatoires', async () => {
  const t = cw();
  await dispute(t, 'r1');
  const before = JSON.stringify(t.order());
  for (const uid of ['sub', 'r1', 'dA', 'c1', 'nobody']) {
    await assert.rejects(() => resolve(t, {}, uid), (e) => e.code === 'permission-denied' || e.code === 'unauthenticated', uid);
  }
  assert.equal((await resolve(t, { requestId: 'court' })).code, 'REQUEST_ID_REQUIRED');
  assert.equal((await resolve(t, { justification: 'court' })).code, 'JUSTIFICATION_REQUIRED');
  assert.equal((await resolve(t, { finalAmount: 3501 })).code, 'AMOUNT_EXCEEDS_DUE');
  for (const finalAmount of [-1, 1.5, '3500', null]) assert.equal((await resolve(t, { finalAmount })).code, 'INVALID_AMOUNT');
  assert.equal(JSON.stringify(t.order()), before);
});

test('résolution intégrale : réglé, tracé, idempotent ; autre requestId refusé ; aucun wallet', async () => {
  const t = cw();
  await dispute(t, 'r1');
  const before = balances(t);
  const r = await resolve(t);
  assert.equal(r.success, true);
  const o = t.order();
  assert.deepEqual([o.cashRemittance.status, o.merchantCashSettled, o.cashRemittance.outstanding], ['resolved', true, 0]);
  assert.deepEqual(
    [o.cashRemittance.resolution.finalAmount, o.cashRemittance.resolution.byUid, o.cashRemittance.resolution.requestId, o.cashRemittance.resolution.previousStatus],
    [3500, 'root', REQ_A, 'disputed']);
  assert.equal(o.cashRemittance.resolution.justification, JUST);
  assert.deepEqual(balances(t), before);
  assert.equal(walletTxKeys(t).length, 0);
  assert.equal([...t.s.keys()].filter((k) => k.startsWith('reconciliation_flags/')).length, 0);
  assert.equal((await resolve(t)).data.replay, true);
  assert.equal((await resolve(t, { requestId: REQ_B })).code, 'CASH_ALREADY_FINAL');
  assert.equal((await confirm(t, 3500)).code, 'CASH_ALREADY_FINAL');
  assert.equal(t.audits.filter((a) => a.action === 'partner_order_resolveCashRemittance' && !a.status).length, 1);
  assert.deepEqual(findingsOf(t), []);
});

test('résolution avec reliquat : montant final décidé, reliquat tracé, JAMAIS débité du wallet', async () => {
  const t = cw();
  await declare(t, 3500);
  await confirm(t, 2000);
  const before = balances(t);
  const r = await resolve(t, { finalAmount: 2000 });
  assert.equal(r.success, true, 'régularisation possible depuis une confirmation partielle sans litige');
  const o = t.order();
  assert.deepEqual([o.cashRemittance.status, o.cashRemittance.outstanding, o.merchantCashSettled, o.cashRemittance.resolution.finalAmount], ['resolved', 1500, true, 2000]);
  assert.deepEqual(balances(t), before, 'aucun débit automatique du livreur');
  assert.equal(walletTxKeys(t).length, 0);
  const flag = t.s.get('reconciliation_flags/o1_cash_shortfall');
  assert.deepEqual([flag.type, flag.status, flag.amount, flag.owedTo, flag.decidedBy], ['cash_shortfall', 'recorded', 1500, 'partner', 'root']);
  assert.deepEqual(findingsOf(t), ['V2_CASH_RESOLVED_SHORTFALL']);
  // Régularisation à 0 depuis un reversement jamais déclaré (livreur injoignable) : permise, reliquat intégral tracé.
  const z = cw();
  assert.equal((await resolve(z, { finalAmount: 0 })).success, true);
  assert.deepEqual([z.order().cashRemittance.outstanding, z.order().merchantCashSettled], [3500, true]);
  assert.equal(z.s.get('reconciliation_flags/o1_cash_shortfall').amount, 3500);
});

test('course transférée : seul le livreur FINAL déclare ; l\'ancien livreur ne peut ni déclarer ni contester', async () => {
  const t = world(cash({ driverId: 'dA', driverHistory: [{ driverId: 'dOld' }, { driverId: 'dA' }], transferCount: 1 }, { driverId: 'dA' }));
  assert.equal((await declare(t, 3500, 'dOld')).code, 'ORDER_NOT_FOUND');
  assert.equal((await dispute(t, 'dOld')).code, 'ORDER_NOT_FOUND');
  assert.equal((await declare(t, 3500, 'dA')).success, true);
  assert.equal(t.order().cashRemittance.handedOverBy, 'dA');
  assert.equal((await dispute(t, 'dA')).success, true);
});

test('préconditions : commande livrée, payée en cash, v2 cohérente, suivi cohérent — sinon refus sans écriture', async () => {
  for (const [label, order, code] of [
    ['non livrée', cash({ status: 'picked_up' }), 'CASH_ORDER_NOT_DELIVERED'],
    ['annulée', cash({ status: 'cancelled' }), 'CASH_ORDER_NOT_DELIVERED'],
    ['wallet', cash({ paymentMethod: 'wallet', isPaid: true }), 'CASH_ORDER_NOT_CASH'],
    ['montants incohérents', cash({ totalAmount: 99999 }), 'ORDER_AMOUNTS_INCONSISTENT'],
    ['suivi absent', cash({ cashRemittance: undefined }), 'CASH_REMITTANCE_INVALID'],
    ['montant dû falsifié', cash({}, { amountDue: 1 }), 'CASH_REMITTANCE_INVALID'],
    ['partenaire du suivi différent', cash({}, { partnerId: 'rX' }), 'CASH_REMITTANCE_INVALID'],
  ]) {
    const t = world(order);
    const before = JSON.stringify(t.order());
    for (const [action, uid, extra] of [['declareCashHandover', 'dA', { amount: 100 }], ['confirmCashRemittance', 'r1', { amount: 100 }],
      ['disputeCashRemittance', 'r1', { reason: 'Un motif suffisamment long' }], ['resolveCashRemittance', 'root', { requestId: REQ_A, justification: JUST, finalAmount: 0 }]]) {
      const r = await t.call(action, uid, extra);
      assert.deepEqual([label, action, r.code], [label, action, code]);
    }
    assert.equal(JSON.stringify(t.order()), before, label);
  }
});

test('commande historique (sans amountsVersion 2) : actions cash refusées, rien n\'est modifié', async () => {
  const t = world(legacy({ status: 'delivered', merchantCashSettled: false }));
  const before = JSON.stringify(t.order());
  assert.equal((await declare(t, 100)).code, 'ORDER_NOT_PARTNER_V2');
  assert.equal((await confirm(t, 100)).code, 'ORDER_NOT_PARTNER_V2');
  assert.equal((await dispute(t, 'r1')).code, 'ORDER_NOT_PARTNER_V2');
  assert.equal((await resolve(t)).code, 'ORDER_NOT_PARTNER_V2');
  assert.equal(JSON.stringify(t.order()), before);
});

test('partenaire ou livreur désactivé : refus', async () => {
  const p = world(cash(), { 'restaurants/r1': { isActive: false } });
  assert.equal((await confirm(p, 3500)).code, 'ACTOR_UNAVAILABLE');
  const d = world(cash(), { 'livreurs/dA': { wallet: 900, isActive: false } });
  assert.equal((await declare(d, 3500)).code, 'ACTOR_UNAVAILABLE');
  assert.equal(p.order().cashRemittance.status, 'pending');
});

test('retard supérieur à 24 h : visible par le rapprochement A2 (alerte), sans aucune sanction ni mouvement', async () => {
  const t = cw(); // deliveredAtMs = 1
  const day = 24 * 3600 * 1000;
  assert.deepEqual(findingsOf(t, day - 1), ['V2_CASH_REMITTANCE_PENDING']);
  assert.deepEqual(findingsOf(t, day + 2), ['V2_CASH_REMITTANCE_OVERDUE']);
  await declare(t, 3500);
  assert.deepEqual(findingsOf(t, day + 2), ['V2_CASH_REMITTANCE_OVERDUE'], 'déclarer sans confirmation ne retire pas l\'alerte');
  assert.deepEqual(balances(t), [16000, 900, 1000]);
});

test('séquences concurrentes : états valides, jamais réglé sans confirmation intégrale ou régularisation, aucun wallet', async () => {
  for (let i = 0; i < 12; i++) {
    const t = cw();
    const calls = [declare(t, 3500), confirm(t, 3500), dispute(t, 'dA'), dispute(t, 'r1'), declare(t, 2000), confirm(t, 2000)];
    if (i % 3 === 0) calls.reverse();
    await Promise.allSettled(calls);
    const o = t.order(); const c = o.cashRemittance;
    assert.ok(['declared', 'confirmed', 'disputed'].includes(c.status), `tour ${i} : ${c.status}`);
    const settled = o.merchantCashSettled === true;
    assert.equal(settled, c.status === 'confirmed' && c.amountConfirmed === 3500, `tour ${i} : règlement cohérent avec l'état`);
    if (c.amountConfirmed !== undefined) assert.ok(c.amountConfirmed <= 3500 && c.amountConfirmed > 0);
    if (c.amountHandedOver !== null) assert.ok(c.amountHandedOver <= 3500);
    assert.deepEqual(balances(t), [16000, 900, 1000]);
    assert.equal(walletTxKeys(t).length, 0);
  }
});

test('résolutions concurrentes avec requestId différents : une seule décision retenue', async () => {
  const t = cw();
  await dispute(t, 'r1');
  const res = await Promise.allSettled([resolve(t, { requestId: REQ_A, finalAmount: 3500 }), resolve(t, { requestId: REQ_B, finalAmount: 1000 }), resolve(t, { requestId: REQ_A, finalAmount: 3500 })]);
  const winner = t.order().cashRemittance.resolution;
  assert.ok([REQ_A, REQ_B].includes(winner.requestId));
  assert.equal(res.filter((r) => r.value?.success && !r.value.data.replay).length, 1, 'une seule décision appliquée');
  assert.equal(t.audits.filter((a) => a.action === 'partner_order_resolveCashRemittance' && !a.status).length, 1);
  assert.equal(walletTxKeys(t).length, 0);
});
