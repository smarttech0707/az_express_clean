'use strict';

// Remboursements partiels A / B / C et total D du litige après récupération (variante D).
// Faux Firestore sérialisé pour la concurrence. Spécification : docs/ORDER_DISPUTES_SPEC.md.

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildAdminOrderDispute, planRefund } = require('../adminOrderDisputes');
const { buildCancelOrder } = require('../orderActions');
const { requireAdminPermission, requireSuperAdmin } = require('../adminGuards');
const { calculateCommission } = require('../dispatch');

const oc = (...a) => ({ run: a[a.length - 1] });
const REQ = (n) => `request-id-0000000${n}`.slice(0, 24).padEnd(20, 'x');
const J = 'Litige constaté après appel du client';
const code = (c) => (e) => e.code === c;

function setup(orderExtra = {}, seedExtra = {}) {
  const db = fakeDb({
    'orders/o1': {
      clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true,
      budget: 1000, shoppingBudget: 2000, pickedUpAt: 1,
      commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
      cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'c1', requestedAtMs: 5 },
      ...orderExtra,
    },
    'clients/c1': { wallet: 7000, name: 'Aya' },
    'livreurs/dA': { wallet: 800, name: 'Kone' },
    'admins/root': { role: 'super', isActive: true },
    'admins/subOk': { role: 'sub', isActive: true, permissions: ['commandes'] },
    'admins/subNo': { role: 'sub', isActive: true, permissions: ['restaurants'] },
    ...seedExtra,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const fn = buildAdminOrderDispute({
    db, admin, onCall: oc, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); },
    requireAdminPermission, requireSuperAdmin, calculateCommission,
  }).run;
  const call = (uid, data) => fn({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  const decide = (uid, decision, n = 1, extra = {}) => call(uid, {
    action: 'decide', orderId: 'o1', decision, requestId: REQ(n), justification: J, shoppingContext: 'not_purchased', ...extra,
  });
  const order = () => db.store.get('orders/o1');
  const money = () => [db.store.get('clients/c1').wallet, db.store.get('livreurs/dA').wallet];
  const walletTx = () => [...db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));
  return { db, call, decide, order, money, audits, walletTx };
}

const conserved = (t) => { const [c, d] = t.money(); return c + d; };
const TOTAL = 7000 + 800 + 3000; // wallets avant litige + montant payé encore « en séquestre »

test('A remboursement du shoppingBudget : client +2000, livreur +1000 (frais), commission conservée, commande close', async () => {
  const t = setup();
  const r = await t.decide('root', 'refundShopping');
  assert.deepEqual([r.refund.clientRefund, r.refund.driverCredit], [2000, 1000]);
  assert.deepEqual(t.money(), [9000, 1800]);
  assert.equal(conserved(t), TOTAL);
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.order().commissionStatus, 'charged');
  assert.equal(t.order().disputeDecision.commissionKept, 200);
  assert.equal(t.order().deliveryClosedBy, 'admin_dispute');
  assert.equal(t.order().cancelRequestAfterPickup.status, 'resolved_partial_refund');
  assert.equal(t.walletTx().length, 2);
});

test('B budget non dépensé : frais ET achat reviennent au client (+3000), livreur +0 — jamais le budget comme rémunération', async () => {
  const t = setup();
  const r = await t.decide('root', 'refundFee');
  assert.deepEqual([r.refund.clientRefund, r.refund.driverCredit], [3000, 0]);
  assert.deepEqual(t.money(), [10000, 800]);
  assert.equal(conserved(t), TOTAL);
  assert.equal(t.walletTx().length, 1);
});

test('C 50 % des frais, budget non dépensé : client +2500 (500 + achat 2000), livreur +500 ; arrondi inférieur', async () => {
  const t = setup();
  const r = await t.decide('root', 'refundHalfFee');
  assert.deepEqual([r.refund.clientRefund, r.refund.driverCredit], [2500, 500]);
  assert.deepEqual(t.money(), [9500, 1300]);
  const odd = setup({ budget: 1001, shoppingBudget: 0 });
  const r2 = await odd.decide('root', 'refundHalfFee', 1, { shoppingContext: undefined });
  assert.deepEqual([r2.refund.clientRefund, r2.refund.driverCredit], [500, 501]);
});

test('D remboursement total : client +3000, commission rendue à son payeur, livreur non payé, une seule fois', async () => {
  const t = setup();
  const r = await t.decide('root', 'exceptionalCancel');
  assert.equal(r.refund.clientRefund, 3000);
  assert.deepEqual(t.money(), [10000, 1000]);
  assert.equal(t.order().commissionStatus, 'refunded');
});

test('invariant : pour toute option et tout montant, remboursé + livreur = payé et jamais plus que le payé', () => {
  for (const budget of [0, 1, 500, 999, 1000, 1001, 2500, 7777]) {
    for (const shoppingBudget of [0, 1, 300, 5000]) {
      for (const d of ['refundShopping', 'refundFee', 'refundHalfFee', 'exceptionalCancel']) {
        const order = { paymentMethod: 'wallet', isPaid: true, budget, shoppingBudget, status: 'picked_up' };
        const p = planRefund(order, d, { shoppingContext: 'not_purchased' });
        if (!p.ok) continue;
        const paid = budget + shoppingBudget;
        assert.equal(p.clientRefund + p.driverCredit, paid, JSON.stringify([budget, shoppingBudget, d]));
        assert.ok(p.clientRefund >= 0 && p.driverCredit >= 0 && p.clientRefund <= paid);
        assert.ok(Number.isInteger(p.clientRefund) && Number.isInteger(p.driverCredit));
      }
    }
  }
});

test('matrice de conservation : contextes × options × budgets, remboursé + livreur = payé, aucun montant négatif', () => {
  for (const ctx of ['not_purchased', 'purchased_returned', 'purchased_delivered', 'purchased_unreturned']) {
    for (const budget of [100, 500, 1001, 2500]) {
      for (const shoppingBudget of [0, 1, 3000]) {
        for (const d of ['refundShopping', 'refundFee', 'refundHalfFee']) {
          const order = { paymentMethod: 'wallet', isPaid: true, budget, shoppingBudget, status: 'picked_up' };
          const p = planRefund(order, d, { shoppingContext: ctx, advancedBy: 'driver_own_funds', justifiedSpentRefund: true, justification: 'x'.repeat(40) });
          if (!p.ok) continue;
          const paid = budget + shoppingBudget;
          assert.equal(p.clientRefund + p.driverReimbursement + p.driverPay, paid, JSON.stringify([ctx, budget, shoppingBudget, d]));
          assert.ok([p.clientRefund, p.driverReimbursement, p.driverPay].every((n) => Number.isInteger(n) && n >= 0));
          const spent = shoppingBudget > 0 && ctx.startsWith('purchased_') && ctx !== 'purchased_returned';
          // Le budget d'achat n'est jamais versé au livreur s'il n'a pas été dépensé.
          if (!spent) assert.equal(p.driverReimbursement, 0);
          if (!spent) assert.ok(p.driverPay <= budget);
        }
      }
    }
  }
});

test('aucune saisie libre : un montant fourni par l’appelant est ignoré, jamais utilisé', async () => {
  const t = setup();
  const r = await t.decide('root', 'refundFee', 1, { amount: 999999, clientRefund: 999999, refundAmount: 999999 });
  assert.equal(r.refund.clientRefund, 3000);
  assert.deepEqual(t.money(), [10000, 800]);
});

test('situation du budget d’achat obligatoire dès qu’il y a un shoppingBudget (toutes options)', async () => {
  const t = setup();
  for (const d of ['refundShopping', 'refundFee', 'refundHalfFee', 'exceptionalCancel']) {
    await assert.rejects(() => t.decide('root', d, 1, { shoppingContext: undefined }), code('failed-precondition'));
  }
  await assert.rejects(() => t.decide('root', 'refundFee', 1, { shoppingContext: 'inconnu' }), code('failed-precondition'));
  assert.deepEqual(t.money(), [7000, 800]);
  assert.equal(t.order().status, 'picked_up');
});

test('budget déjà dépensé (remis au client / non retourné) : A et D refusés sans décision justifiée ; B et C possibles', async () => {
  for (const ctx of ['purchased_delivered', 'purchased_unreturned']) {
    const t = setup();
    await assert.rejects(() => t.decide('root', 'refundShopping', 1, { shoppingContext: ctx }), code('failed-precondition'));
    await assert.rejects(() => t.decide('root', 'exceptionalCancel', 2, { shoppingContext: ctx }), code('failed-precondition'));
    await assert.rejects(() => t.decide('root', 'exceptionalCancel', 3, { shoppingContext: ctx, justifiedSpentRefund: true, justification: 'Litige avéré ok' }), code('failed-precondition'));
    assert.deepEqual(t.money(), [7000, 800]);
    // B/C sur budget dépensé : refusé sans déclaration d'avance du livreur (aucune règle de paiement inventée).
    await assert.rejects(() => t.decide('root', 'refundFee', 5, { shoppingContext: ctx }), code('failed-precondition'));
    await assert.rejects(() => t.decide('root', 'refundHalfFee', 6, { shoppingContext: ctx }), code('failed-precondition'));
    assert.deepEqual(t.money(), [7000, 800]);
    const ok = await t.decide('root', 'refundFee', 4, { shoppingContext: ctx, advancedBy: 'driver_own_funds' });
    assert.deepEqual([ok.refund.clientRefund, ok.refund.driverReimbursement, ok.refund.driverPay], [1000, 2000, 0]);
    assert.deepEqual(t.money(), [8000, 2800]);
    assert.equal(t.order().disputeDecision.advancedBy, 'driver_own_funds');
    const types = [...t.db.store.entries()].filter(([k]) => k.startsWith('livreurs/dA/wallet_transactions/')).map(([, v]) => v.type);
    assert.deepEqual(types, ['reimbursement']);
  }
});

test('C budget dépensé avancé par le livreur : client +500, remboursement achat +2000 et rémunération +500 en deux écritures', async () => {
  const t = setup();
  const r = await t.decide('root', 'refundHalfFee', 1, { shoppingContext: 'purchased_unreturned', advancedBy: 'driver_own_funds' });
  assert.deepEqual([r.refund.clientRefund, r.refund.driverReimbursement, r.refund.driverPay], [500, 2000, 500]);
  assert.deepEqual(t.money(), [7500, 3300]);
  assert.equal(conserved(t), TOTAL);
});

test('A sur budget dépensé justifié : client remboursé, avance du livreur signalée (jamais compensée automatiquement)', async () => {
  const t = setup();
  const why = 'Le client n’a jamais reçu les produits achetés, preuve par appel enregistré et photo du livreur.';
  await t.decide('root', 'refundShopping', 1, { shoppingContext: 'purchased_unreturned', justifiedSpentRefund: true, justification: why, advancedBy: 'driver_own_funds' });
  assert.deepEqual(t.money(), [9000, 1800]);
  const flags = [...t.db.store.entries()].filter(([k]) => k.startsWith('reconciliation_flags/o1_driver_advance_')).map(([, v]) => v);
  assert.deepEqual(flags.map((f) => [f.type, f.status, f.amount, f.driverId]), [['driver_advance_unreimbursed', 'open', 2000, 'dA']]);
});

test('budget dépensé mais décision justifiée par écrit (≥ 30 caractères) : remboursement possible et tracé', async () => {
  const t = setup();
  const why = 'Le client n’a jamais reçu les produits achetés, preuve par appel enregistré et photo du livreur.';
  const r = await t.decide('root', 'refundShopping', 1, { shoppingContext: 'purchased_delivered', justifiedSpentRefund: true, justification: why });
  assert.equal(r.refund.clientRefund, 2000);
  assert.equal(t.order().disputeDecision.shoppingContext, 'purchased_delivered');
  assert.equal(t.audits[0].metadata.shoppingContext, 'purchased_delivered');
});

test('produits retournés : le budget d’achat est remboursable sans décision spéciale', async () => {
  const t = setup();
  const r = await t.decide('root', 'exceptionalCancel', 1, { shoppingContext: 'purchased_returned' });
  assert.equal(r.refund.clientRefund, 3000);
});

test('cash ou wallet non payé : aucune option de remboursement partiel, aucun mouvement', async () => {
  for (const extra of [{ paymentMethod: 'cash', isPaid: false }, { isPaid: false }]) {
    for (const d of ['refundShopping', 'refundFee', 'refundHalfFee']) {
      const t = setup(extra);
      await assert.rejects(() => t.decide('root', d), code('failed-precondition'));
      assert.deepEqual(t.money(), [7000, 800]);
      assert.equal(t.order().status, 'picked_up');
    }
  }
});

test('livreur déjà payé ou gain retenu : partiel refusé, aucun double paiement', async () => {
  for (const extra of [{ heldDriverEarning: 1000 }, { settlementStatus: 'pending_admin_review' }, { deliveredAt: 5 }]) {
    const t = setup(extra);
    await assert.rejects(() => t.decide('root', 'refundFee'), code('failed-precondition'));
    assert.deepEqual(t.money(), [7000, 800]);
  }
});

test('course transférée : partiel refusé (règlement de transfert dédié)', async () => {
  const t = setup({ settlementHold: true });
  await assert.rejects(() => t.decide('root', 'refundFee'), code('failed-precondition'));
});

test('vendeur : jamais débité automatiquement ; partiel refusé ; remboursement total → signalement de rapprochement', async () => {
  const t = setup({ sellerId: 'r1', sellerType: 'restaurant' }, { 'restaurants/r1': { wallet: 5000, name: 'Chez Awa' } });
  await assert.rejects(() => t.decide('root', 'refundFee'), code('failed-precondition'));
  assert.equal(t.db.store.get('restaurants/r1').wallet, 5000);
  const r = await t.decide('root', 'exceptionalCancel', 2);
  assert.equal(r.refund.clientRefund, 3000);
  assert.equal(t.db.store.get('restaurants/r1').wallet, 5000, 'wallet vendeur intact');
  const flag = [...t.db.store.entries()].find(([k]) => k.startsWith('reconciliation_flags/o1_seller_'))[1];
  assert.deepEqual([flag.type, flag.status, flag.sellerId, flag.decidedBy], ['seller_review', 'open', 'r1', 'root']);
});

test('les trois remboursements partiels sont réservés au super-admin', async () => {
  const t = setup();
  for (const d of ['refundShopping', 'refundFee', 'refundHalfFee']) {
    await assert.rejects(() => t.decide('subOk', d), code('permission-denied'));
    await assert.rejects(() => t.decide('c1', d), code('permission-denied'));
    await assert.rejects(() => t.decide('dA', d), code('permission-denied'));
  }
  assert.deepEqual(t.money(), [7000, 800]);
  assert.equal(t.order().status, 'picked_up');
});

test('partiel : même requestId rejoué → aucun second mouvement ; autre requestId → refusé (commande close)', async () => {
  const t = setup();
  await t.decide('root', 'refundFee', 1);
  const again = await t.decide('root', 'refundFee', 1);
  assert.equal(again.replay, true);
  await assert.rejects(() => t.decide('root', 'refundFee', 2), code('failed-precondition'));
  await assert.rejects(() => t.decide('root', 'refundShopping', 3), code('failed-precondition'));
  assert.deepEqual(t.money(), [10000, 800]);
  assert.equal(t.audits.filter((a) => a.status === 'success').length, 1);
  assert.equal(t.walletTx().length, 1);
});

test('concurrence : A, B, C et D simultanés → une seule décision financière, argent conservé', async () => {
  const t = setup();
  const results = await Promise.allSettled([
    t.decide('root', 'refundShopping', 1), t.decide('root', 'refundFee', 2),
    t.decide('root', 'refundHalfFee', 3), t.decide('root', 'exceptionalCancel', 4),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(t.audits.filter((a) => a.status === 'success').length, 1);
  const delta = conserved(t) - (7000 + 800);
  // partiel : 3000 répartis ; total : 3000 au client + 200 de commission rendue.
  assert.ok(delta === 3000 || delta === 3200, `delta ${delta}`);
});

test('concurrence : remboursement partiel + annulation du client simultanés → un seul mouvement', async () => {
  const t = setup();
  const cancel = buildCancelOrder({
    db: t.db, admin, onCall: oc, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission,
  }).run;
  const results = await Promise.allSettled([
    cancel({ auth: { uid: 'c1', token: {} }, data: { orderId: 'o1' } }),
    t.decide('root', 'refundFee', 1),
    cancel({ auth: { uid: 'c1', token: {} }, data: { orderId: 'o1' } }),
  ]);
  assert.equal(results[0].status, 'rejected');
  assert.equal(results[1].status, 'fulfilled');
  assert.deepEqual(t.money(), [10000, 800]);
});

test('dossier : options chiffrées par le serveur (aperçu), vérifications financières, aucune donnée sensible', async () => {
  const t = setup();
  const d = (await t.call('subOk', { action: 'get', orderId: 'o1' })).dispute;
  const pick = (o) => [o.clientRefund, o.driverReimbursement, o.driverPay, o.driverCredit];
  assert.deepEqual(pick(d.options.refundShopping), [2000, 0, 1000, 1000]);
  assert.deepEqual(pick(d.options.refundFee), [3000, 0, 0, 0]);
  assert.deepEqual(pick(d.options.refundFee.ifSpent), [1000, 2000, 0, 2000]);
  assert.deepEqual(pick(d.options.refundHalfFee), [2500, 0, 500, 500]);
  assert.deepEqual(pick(d.options.refundHalfFee.ifSpent), [500, 2000, 500, 2500]);
  assert.deepEqual(pick(d.options.exceptionalCancel), [3000, 0, 0, 0]);
  assert.deepEqual([d.checks.driverAlreadyPaid, d.checks.commissionCharged, d.checks.needsShoppingContext], [false, true, true]);
  const cash = (await setup({ paymentMethod: 'cash', isPaid: false }).call('subOk', { action: 'get', orderId: 'o1' })).dispute;
  assert.equal(cash.options.refundFee.available, false);
});

test('D avec commission NON tracée : rien n’est rendu au livreur, signalement idempotent, client remboursé', async () => {
  const t = setup({ commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined });
  const r = await t.decide('root', 'exceptionalCancel');
  assert.equal(r.refund.clientRefund, 3000);
  assert.deepEqual(t.money(), [10000, 800], 'aucun crédit livreur sans preuve de prélèvement');
  const flags = [...t.db.store.entries()].filter(([k]) => k.startsWith('reconciliation_flags/o1_commission_untraced'));
  assert.equal(flags.length, 1);
  assert.deepEqual([flags[0][1].type, flags[0][1].status, flags[0][1].driverId], ['commission_untraced', 'open', 'dA']);
  const again = await t.decide('root', 'exceptionalCancel');
  assert.equal(again.replay, true);
  assert.deepEqual(t.money(), [10000, 800]);
});

test('commission « charged » sans montant entier fiable : traitée comme non tracée (aucun crédit)', async () => {
  const t = setup({ commissionAmount: '200' });
  await t.decide('root', 'exceptionalCancel');
  assert.deepEqual(t.money(), [10000, 800]);
});

test('commission tracée : rendue une seule fois à son payeur d’origine, même après un rejeu', async () => {
  const t = setup();
  await t.decide('root', 'exceptionalCancel');
  await t.decide('root', 'exceptionalCancel');
  assert.deepEqual(t.money(), [10000, 1000]);
  assert.equal(t.order().commissionStatus, 'refunded');
});

test('avance du livreur (A/D sur achat dépensé) : montant tracé, signalement unique, aucune compensation automatique', async () => {
  const why = 'Le client n’a jamais reçu les produits achetés, preuve par appel enregistré et photo du livreur.';
  for (const d of ['refundShopping', 'exceptionalCancel']) {
    const t = setup();
    const extra = { shoppingContext: 'purchased_unreturned', justifiedSpentRefund: true, justification: why, advancedBy: 'driver_own_funds' };
    await t.decide('root', d, 1, extra);
    await t.decide('root', d, 1, extra); // rejeu
    const flags = [...t.db.store.entries()].filter(([k]) => k.startsWith('reconciliation_flags/o1_driver_advance_'));
    assert.equal(flags.length, 1);
    assert.deepEqual([flags[0][1].type, flags[0][1].amount, flags[0][1].driverId, flags[0][1].status], ['driver_advance_unreimbursed', 2000, 'dA', 'open']);
    // Aucune ligne de remboursement d'achats pour le livreur.
    const types = [...t.db.store.entries()].filter(([k]) => k.startsWith('livreurs/dA/wallet_transactions/')).map(([, v]) => v.type);
    assert.ok(!types.includes('reimbursement'));
    // La commande est close : une seconde décision ne peut pas créer une seconde avance à régler.
    await assert.rejects(() => t.decide('root', d, 2, extra), code('failed-precondition'));
    assert.equal([...t.db.store.keys()].filter((k) => k.startsWith('reconciliation_flags/o1_driver_advance_')).length, 1);
  }
});

test('concurrence A/B/C/D + avances + commission non tracée : une seule décision, au plus un signalement d’avance', async () => {
  const why = 'Le client n’a jamais reçu les produits achetés, preuve par appel enregistré et photo du livreur.';
  for (const untraced of [false, true]) {
    const t = setup(untraced ? { commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined } : {});
    const extra = { shoppingContext: 'purchased_delivered', advancedBy: 'driver_own_funds', justifiedSpentRefund: true, justification: why };
    const results = await Promise.allSettled([
      t.decide('root', 'refundShopping', 1, extra), t.decide('root', 'refundFee', 2, extra),
      t.decide('root', 'refundHalfFee', 3, extra), t.decide('root', 'exceptionalCancel', 4, extra),
      t.decide('root', 'refundFee', 2, extra),
    ]);
    assert.equal(results.filter((r) => r.status === 'fulfilled' && !r.value.replay).length, 1);
    const delta = conserved(t) - (7000 + 800);
    // 3000 payés répartis ; D : + commission rendue seulement si tracée.
    assert.ok(delta === 3000 || (delta === 3200 && !untraced), `delta ${delta} untraced=${untraced}`);
    const adv = [...t.db.store.keys()].filter((k) => k.startsWith('reconciliation_flags/o1_driver_advance_')).length;
    assert.ok(adv <= 1, `avances ${adv}`);
  }
});

test('listDisputes et listReconciliation : permission `commandes`, champs utiles seulement', async () => {
  const t = setup({}, { 'reconciliation_flags/o1_seller': { orderId: 'o1', type: 'seller_review', status: 'open', sellerId: 'r1', sellerType: 'restaurant', reason: 'refund_total', createdAtMs: 5, decidedBy: 'root' } });
  const base = t.db.collection;
  t.db.collection = (name) => {
    const c = base(name);
    const docsOf = (prefix, pred) => [...t.db.store.entries()].filter(([k]) => k.startsWith(prefix) && pred(t.db.store.get(k)))
      .map(([k, v]) => ({ id: k.split('/').pop(), data: () => v }));
    if (name === 'orders') return { ...c, where: () => ({ limit: () => ({ get: async () => ({ docs: docsOf('orders/', (o) => o.cancelRequestAfterPickup?.status === 'pending_admin_review') }) }) }) };
    if (name === 'reconciliation_flags') return { ...c, where: () => ({ limit: () => ({ get: async () => ({ docs: docsOf('reconciliation_flags/', (f) => f.status === 'open') }) }) }) };
    return c;
  };
  const d = await t.call('subOk', { action: 'listDisputes' });
  assert.deepEqual(d.disputes.map((x) => [x.orderId, x.paid, x.driverId]), [['o1', 3000, 'dA']]);
  const f = await t.call('subOk', { action: 'listReconciliation' });
  assert.deepEqual(f.flags.map((x) => [x.orderId, x.sellerId, x.type]), [['o1', 'r1', 'seller_review']]);
  assert.doesNotMatch(JSON.stringify([d, f]), /decidedBy|"wallet":|phone/);
  for (const a of ['listDisputes', 'listReconciliation']) {
    await assert.rejects(() => t.call('subNo', { action: a }), code('permission-denied'));
    await assert.rejects(() => t.call('c1', { action: a }), code('permission-denied'));
  }
});
