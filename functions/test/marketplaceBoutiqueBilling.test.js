'use strict';

// Facturation et rémunération des livraisons Marketplace / Boutique.
//
// Règle métier : le client paie séparément les produits ET la livraison.
// Exemple de référence (produits 5000, livraison 500) :
//   client 5500 = vendeur 5000 + commission AZ 100 + gain net livreur 400.
// Les vraies fonctions (création, acceptOrderCF, deliverOrderCF, cancelOrderCF,
// remboursement boutique) tournent sur un faux Firestore ; l'invariant vérifié
// partout est la conservation exacte des FCFA.

const test = require('node:test');
const assert = require('node:assert/strict');
const { world, photo, ts } = require('./billingWorld');
const { createMarketplaceOrder } = require('../azia/tools/marketplace');
const { HttpsError } = require('firebase-functions/v2/https');
const { admin } = require('./billingWorld');
const tarifService = require('../tarifService');
const { buildAmounts, readAmounts } = require('../orderAmounts');

// ───────────────────────────── barème et helpers ─────────────────────────────
test('orderAmounts : total = produits + livraison, budget = livraison ; incohérence = commande historique', () => {
  const a = buildAmounts(5000, 500);
  assert.deepEqual(a, { amountsVersion: 1, productAmount: 5000, deliveryFee: 500, totalAmount: 5500, budget: 500 });
  assert.deepEqual(readAmounts(a), { productAmount: 5000, deliveryFee: 500, totalAmount: 5500 });
  assert.equal(readAmounts({ ...a, totalAmount: 9999 }), null);
  assert.equal(readAmounts({ ...a, budget: 5000 }), null);
  assert.equal(readAmounts({ budget: 5000 }), null);
  assert.throws(() => buildAmounts(0, 500));
  assert.throws(() => buildAmounts(5000, 0));
  assert.throws(() => buildAmounts(5000.5, 500));
});

// ───────────────────────────── marketplace wallet ─────────────────────────────
for (const [fee, commission] of [[500, 100], [1000, 200]]) {
  test(`marketplace wallet, livraison ${fee} : client −${5000 + fee}, vendeur +5000, commission ${commission}, livreur net +${fee - commission}`, async () => {
    const h = world();
    const before = h.totalMoney();
    const id = await h.marketplace({ deliveryFee: fee });
    assert.equal(h.w('clients/c1'), 10000 - 5000 - fee);
    assert.equal(h.w('sellers/s1'), 5000); // produits seuls, 0 % commission
    h.assign(id);
    await h.call('accept', 'dA', { orderId: id });
    assert.equal(h.w('livreurs/dA'), 1000 - commission); // commission sur les FRAIS, une fois
    assert.equal(h.get(`orders/${id}`).commissionAmount, commission);
    h.pickUp(id);
    await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
    assert.equal(h.w('livreurs/dA'), 1000 - commission + fee);
    assert.equal(h.w('sellers/s1'), 5000); // aucun second crédit vendeur
    const clientOut = 10000 - h.w('clients/c1');
    const driverNet = h.w('livreurs/dA') - 1000;
    assert.equal(driverNet, fee - commission);
    assert.equal(clientOut, h.w('sellers/s1') + driverNet + h.commissionsLogged());
    assert.equal(h.commissionsLogged(), commission);
    // Conservation : l'argent sorti du système = commission AZ uniquement.
    assert.equal(before - h.totalMoney(), commission);
  });
}

test('marketplace wallet : rejeu de la livraison — aucun second crédit livreur, vendeur ni commission', async () => {
  const h = world();
  const id = await h.marketplace();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  const snapshot = [h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA'), h.commissionsLogged()];
  await assert.rejects(() => h.call('deliver', 'dA', { orderId: id }), (e) => e.code === 'failed-precondition');
  await assert.rejects(() => h.call('accept', 'dA', { orderId: id }));
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA'), h.commissionsLogged()], snapshot);
});

test('marketplace wallet : solde insuffisant pour produits + livraison — rien n’est débité', async () => {
  const h = world({ 'clients/c1': { wallet: 5499 } });
  await assert.rejects(() => h.marketplace(), (e) => e.code === 'failed-precondition');
  assert.equal(h.w('clients/c1'), 5499);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.keys('orders/').length, 0);
});

test('marketplace : l’outil AZ IA calcule la livraison côté serveur (jour 500, nuit 1000) et affiche sous-total / livraison / total', async () => {
  const original = tarifService.compute;
  try {
    for (const [hour, fee] of [[12, 500], [22, 1000]]) {
      tarifService.compute = (a) => original({ ...a, time: new Date(2026, 0, 5, hour, 0) });
      const h = world();
      const tool = createMarketplaceOrder({ db: h.db, admin, HttpsError });
      const out = await tool.handler('c1', {
        productId: 'p1', quantity: 1, deliveryLat: 6.7273, deliveryLng: -3.4961, paymentMethod: 'wallet',
      });
      assert.equal(out.status, 'awaiting_confirmation');
      assert.match(out.summaryFr, new RegExp(`produits 5000 FCFA \\+ livraison ${fee} FCFA = total ${5000 + fee} FCFA`));
      const pending = h.get(`ai_pending_actions/${out.actionId}`);
      assert.equal(pending.amount, 5000 + fee); // montant à confirmer = total débité
      assert.equal(pending.toolInput.deliveryFee, fee);
      assert.equal(pending.toolInput.productAmount, 5000);
    }
  } finally {
    tarifService.compute = original;
  }
});

test('marketplace : montants incohérents refusés ; une action en attente historique (budget seul) reste facturée produits seuls', async () => {
  const h = world();
  const tool = createMarketplaceOrder({ db: h.db, admin, HttpsError });
  const base = { productId: 'p1', quantity: 1, title: 'x', sellerId: 's1', sellerName: 'V',
    pickupLat: 6.7, pickupLng: -3.5, deliveryLat: 6.7, deliveryLng: -3.5, paymentMethod: 'wallet' };
  // total ≠ produits + livraison : refusé, rien débité.
  await assert.rejects(
    () => h.db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', {
      ...base, productAmount: 5000, deliveryFee: 500, totalAmount: 1 })),
    (e) => e.code === 'failed-precondition');
  assert.equal(h.w('clients/c1'), 10000);
  // budget invalide : refusé.
  await assert.rejects(
    () => h.db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', { ...base, budget: -5 })),
    (e) => e.code === 'failed-precondition');
  // Action créée avant le déploiement (budget seul) : produits seuls, jamais plus que ce qui était affiché.
  await h.db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', { ...base, budget: 5000 }));
  assert.equal(h.w('clients/c1'), 5000);
  assert.equal(h.w('sellers/s1'), 5000);
});

// ───────────────────────────── marketplace cash ─────────────────────────────
for (const [fee, commission] of [[500, 100], [1000, 200]]) {
  test(`marketplace cash, livraison ${fee} : détail tracé (encaissé ${5000 + fee}, dû vendeur 5000, livreur net ${fee - commission})`, async () => {
    const h = world();
    const id = await h.marketplace({ deliveryFee: fee, paymentMethod: 'cash' });
    assert.equal(h.w('clients/c1'), 10000); // rien débité au client
    assert.equal(h.w('sellers/s1'), 0);
    h.assign(id);
    await h.call('accept', 'dA', { orderId: id });
    h.pickUp(id);
    await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
    // Aucun mouvement de wallet à la livraison (cash) : seule la commission a été prélevée.
    assert.equal(h.w('livreurs/dA'), 1000 - commission);
    assert.equal(h.w('sellers/s1'), 0);
    const order = h.get(`orders/${id}`);
    assert.equal(order.merchantCashSettled, false); // le livreur doit reverser les produits
    assert.deepEqual(order.cashBreakdown, {
      productAmount: 5000, deliveryFee: fee, cashCollected: 5000 + fee, dueToSeller: 5000,
      driverGross: fee, commissionAmount: commission, driverNet: fee - commission,
    });
    // Conservation en espèces : encaissé = dû vendeur + gain brut livreur.
    assert.equal(order.cashBreakdown.cashCollected, order.cashBreakdown.dueToSeller + order.cashBreakdown.driverGross);
    assert.equal(h.commissionsLogged(), commission);
  });
}

// ───────────────────────────── boutique wallet ─────────────────────────────
for (const [fee, commission] of [[500, 100]]) {
  test('boutique wallet : client −5500, vendeur +5000, frais 500 au livreur à la livraison, commission 100 une seule fois', async () => {
    const h = world();
    const before = h.totalMoney();
    const r = await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
    assert.deepEqual([r.totalPrice, r.deliveryFee, r.totalAmount], [5000, fee, 5000 + fee]);
    assert.equal(h.w('clients/c1'), 10000 - 5000 - fee);
    assert.equal(h.w('sellers/s1'), 5000);
    const delivery = h.keys('orders/')[0].split('/')[1];
    const bo = h.get(`boutique_orders/${h.keys('boutique_orders/')[0].split('/')[1]}`);
    assert.deepEqual([bo.productAmount, bo.deliveryFee, bo.totalAmount], [5000, fee, 5000 + fee]);
    assert.equal(h.get(`orders/${delivery}`).deliveryFeePaid, true);
    h.assign(delivery);
    await h.call('accept', 'dA', { orderId: delivery });
    assert.equal(h.w('livreurs/dA'), 1000 - commission);
    h.pickUp(delivery);
    await h.call('deliver', 'dA', { orderId: delivery, deliveryPhotoUrl: photo });
    assert.equal(h.w('livreurs/dA'), 1000 - commission + fee);
    assert.equal(h.w('sellers/s1'), 5000); // pas de second paiement vendeur
    assert.equal(h.get(`boutique_orders/${h.keys('boutique_orders/')[0].split('/')[1]}`).status, 'delivered');
    assert.equal(before - h.totalMoney(), commission);
    assert.equal(h.commissionsLogged(), commission);
    // Rejeu : rien ne bouge.
    const snap = [h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')];
    await assert.rejects(() => h.call('deliver', 'dA', { orderId: delivery }));
    assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], snap);
  });
}

test('boutique wallet : solde insuffisant (produits seuls couverts, pas la livraison) — SOLDE_INSUFFISANT annonce le total', async () => {
  const h = world({ 'clients/c1': { wallet: 5200 } });
  await assert.rejects(
    () => h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 }),
    (e) => e.code === 'failed-precondition' && e.message === 'SOLDE_INSUFFISANT:5200:5500');
  assert.equal(h.w('clients/c1'), 5200);
  assert.equal(h.get('boutique_products/b1').stock, 10);
});

// ───────────────────────────── boutique cash ─────────────────────────────
test('boutique cash : rien de débité, détail tracé (encaissé 5500, dû vendeur 5000, livreur net 400)', async () => {
  const h = world();
  const r = await h.call('payBoutiqueCash', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
  assert.deepEqual([r.totalPrice, r.deliveryFee, r.totalAmount], [5000, 500, 5500]);
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
  const delivery = h.keys('orders/')[0].split('/')[1];
  assert.equal(h.get(`orders/${delivery}`).deliveryFeePaid, false);
  h.assign(delivery);
  await h.call('accept', 'dA', { orderId: delivery });
  h.pickUp(delivery);
  await h.call('deliver', 'dA', { orderId: delivery, deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 900); // aucun crédit en cash : seule la commission a été prélevée
  assert.equal(h.w('sellers/s1'), 0);
  const order = h.get(`orders/${delivery}`);
  assert.equal(order.merchantCashSettled, undefined); // suivi boutique : boutique_orders (admin_boutique_page)
  assert.deepEqual(
    [order.cashBreakdown.cashCollected, order.cashBreakdown.dueToSeller, order.cashBreakdown.driverNet],
    [5500, 5000, 400]);
  const bo = h.get(h.keys('boutique_orders/')[0]);
  assert.equal(bo.totalPrice, 5000); // montant dû au vendeur inchangé pour l’écran admin
});

// ───────────────────────────── annulations et remboursements ─────────────────────────────
for (const phase of ['pending', 'accepted']) {
  test(`marketplace wallet annulée avant récupération (${phase}) : client rendu 5500, vendeur repris 5000, commission rendue, rejeu sans effet`, async () => {
    const h = world();
    const before = h.totalMoney();
    const id = await h.marketplace();
    if (phase !== 'pending') {
      h.assign(id);
      await h.call('accept', 'dA', { orderId: id });
      if (phase === 'picked_up') h.pickUp(id);
    }
    await h.call('cancel', 'c1', { orderId: id });
    assert.equal(h.w('clients/c1'), 10000);
    assert.equal(h.w('sellers/s1'), 0);
    assert.equal(h.w('livreurs/dA'), 1000);
    assert.equal(h.totalMoney(), before);
    await assert.rejects(() => h.call('cancel', 'c1', { orderId: id }));
    assert.equal(h.totalMoney(), before);
    assert.equal(h.w('clients/c1'), 10000);
  });
}

test('marketplace cash annulée : aucun remboursement (rien n’avait été payé), commission rendue', async () => {
  const h = world();
  const id = await h.marketplace({ paymentMethod: 'cash' });
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  await h.call('cancel', 'c1', { orderId: id });
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.w('livreurs/dA'), 1000);
});

test('marketplace wallet livrée : l’annulation est refusée (pas de remboursement après livraison)', async () => {
  const h = world();
  const id = await h.marketplace();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  const snap = [h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')];
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: id }), (e) => e.code === 'failed-precondition');
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], snap);
});

test('marketplace wallet : vendeur ayant déjà retiré une partie — reprise plafonnée, jamais de solde négatif', async () => {
  const h = world();
  const id = await h.marketplace();
  h.set('sellers/s1', { ...h.get('sellers/s1'), wallet: 1200 });
  await h.call('cancel', 'c1', { orderId: id });
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.w('clients/c1'), 10000);
});

function expireBoutique(h) {
  const key = h.keys('boutique_orders/')[0];
  h.set(key, { ...h.get(key), deliveryDeadline: ts(Date.now() - 1000) });
  return key.split('/')[1];
}

test('boutique wallet : remboursement 48 h = produits + livraison, vendeur rend 5000, une seule fois', async () => {
  const h = world();
  const before = h.totalMoney();
  await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
  const boId = expireBoutique(h);
  await h.call('refund', 'c1', { orderId: boId });
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.totalMoney(), before);
  await assert.rejects(() => h.call('refund', 'c1', { orderId: boId }), (e) => e.code === 'failed-precondition');
  assert.equal(h.w('clients/c1'), 10000);
});

for (const status of ['accepted', 'picked_up']) {
  test(`boutique wallet : remboursement refusé tant que la livraison est ${status} (frais dus au livreur, pas de course orpheline)`, async () => {
    const h = world();
    await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
    const delivery = h.keys('orders/')[0].split('/')[1];
    h.assign(delivery);
    await h.call('accept', 'dA', { orderId: delivery });
    if (status === 'picked_up') h.pickUp(delivery);
    const boId = expireBoutique(h);
    await assert.rejects(() => h.call('refund', 'c1', { orderId: boId }), (e) => e.code === 'failed-precondition');
    assert.equal(h.w('clients/c1'), 4500);
    assert.equal(h.w('sellers/s1'), 5000);
    // La livraison peut ensuite se terminer normalement : le livreur est payé, aucun remboursement possible après.
    h.pickUp(delivery);
    await h.call('deliver', 'dA', { orderId: delivery, deliveryPhotoUrl: photo });
    assert.equal(h.w('livreurs/dA'), 1000 - 100 + 500);
    await assert.rejects(() => h.call('refund', 'c1', { orderId: boId }), (e) => e.code === 'failed-precondition');
    assert.equal(h.w('clients/c1'), 4500);
  });
}

test('boutique wallet remboursée avant livraison : la course liée ne peut plus être livrée (pas de gain livreur sur une commande remboursée)', async () => {
  const h = world();
  await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
  const delivery = h.keys('orders/')[0].split('/')[1];
  const boId = expireBoutique(h);
  await h.call('refund', 'c1', { orderId: boId });
  h.set(`orders/${delivery}`, { ...h.get(`orders/${delivery}`), status: 'picked_up', driverId: 'dA' });
  await assert.rejects(() => h.call('deliver', 'dA', { orderId: delivery }), (e) => e.code === 'failed-precondition');
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.w('clients/c1'), 10000);
});

test('boutique wallet annulée avant récupération : produits + livraison rendus, vendeur repris, commande boutique remboursée une fois', async () => {
  const h = world();
  const before = h.totalMoney();
  await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 });
  const delivery = h.keys('orders/')[0].split('/')[1];
  h.assign(delivery);
  await h.call('accept', 'dA', { orderId: delivery });
  await h.call('cancel', 'c1', { orderId: delivery });
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], [10000, 0, 1000]);
  assert.equal(h.totalMoney(), before);
  assert.equal(h.get(h.keys('boutique_orders/')[0]).status, 'refunded');
  // Le remboursement 48 h ne peut plus rembourser une seconde fois.
  const boId = expireBoutique(h);
  await assert.rejects(() => h.call('refund', 'c1', { orderId: boId }), (e) => e.code === 'failed-precondition');
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: delivery }));
  assert.equal(h.w('clients/c1'), 10000);
});

// ───────────────────────────── non-régression ─────────────────────────────
test('commande historique déjà acceptée : la commission tracée est rendue à la livraison, livreur non rémunéré, vendeur inchangé', async () => {
  const h = world({
    'orders/old': { clientId: 'c1', status: 'picked_up', driverId: 'dA', paymentMethod: 'wallet', budget: 5000,
      isPaid: true, sellerId: 's1', sellerType: 'seller', commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200 },
    'sellers/s1': { wallet: 5000 }, 'livreurs/dA': { wallet: 800 },
  });
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 1000); // 800 + 200 rendus : AZ ne garde aucune commission sans contrepartie
  assert.equal(h.w('sellers/s1'), 5000);
  assert.equal(h.get('orders/old').commissionStatus, 'refunded');
  const h2 = world({
    'orders/old': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', budget: 5000, isPaid: true,
      sellerId: 's1', sellerType: 'seller' },
    'clients/c1': { wallet: 0 }, 'sellers/s1': { wallet: 5000 },
  });
  await h2.call('cancel', 'c1', { orderId: 'old' });
  assert.deepEqual([h2.w('clients/c1'), h2.w('sellers/s1')], [5000, 0]);
});

test('commande dont les montants ont été altérés : traitée comme historique, jamais de crédit livreur sur des frais invérifiables', async () => {
  const h = world();
  h.set('config/billing', { ...(h.get('config/billing') || {}), legacyPartnerAcceptance: 'no_commission' });
  const id = await h.marketplace();
  h.set(`orders/${id}`, { ...h.get(`orders/${id}`), deliveryFee: 9999 }); // total ≠ produits + frais
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  const driverAfterAccept = h.w('livreurs/dA');
  h.pickUp(id);
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), driverAfterAccept);
});

test('livraison ordinaire (non partenaire) : barème et crédit inchangés — wallet 500, commission 100, livreur +500', async () => {
  const h = world({
    'orders/o9': { clientId: 'c1', status: 'assigned', driverId: 'dA', budget: 500, description: 'Course',
      paymentMethod: 'wallet', isPaid: true, pickupCityId: 'abengourou' },
  });
  await h.call('accept', 'dA', { orderId: 'o9' });
  assert.equal(h.w('livreurs/dA'), 900);
  h.set('orders/o9', { ...h.get('orders/o9'), status: 'picked_up' });
  await h.call('deliver', 'dA', { orderId: 'o9', deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 1400);
});

test('le barème de livraison n’a pas été modifié : 500 jour / 1000 nuit (standard), 1000 / 1500 (express)', () => {
  const day = tarifService.compute({ clientLat: 6.7273, clientLng: -3.4961, time: new Date(2026, 0, 5, 12) });
  const night = tarifService.compute({ clientLat: 6.7273, clientLng: -3.4961, time: new Date(2026, 0, 5, 22) });
  assert.deepEqual([day.standardPrice, day.expressPrice, night.standardPrice, night.expressPrice], [500, 1000, 1000, 1500]);
});
