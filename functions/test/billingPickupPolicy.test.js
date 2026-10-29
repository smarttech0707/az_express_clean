'use strict';

// Règle commerciale (Marketplace / Boutique, montants explicites) :
//  - avant récupération : remboursement intégral (aucune prestation réalisée) ;
//  - après récupération : frais de livraison non remboursés automatiquement,
//    retenus (deliveryFeeHold) en attente d'examen administratif ;
//  - faute du livreur ou d'AZ : remboursement possible sur décision administrative.
// Aucun paiement fictif : l'argent retenu est celui que le client a déjà payé.

const test = require('node:test');
const assert = require('node:assert/strict');
const { world, photo } = require('./billingWorld');

const PAY = { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 };
const ADMIN = (h, data) => h.call('adminBilling', 'root', { justification: 'Examen du dossier par AZ', ...data });
const hold = (h, id) => h.get(`orders/${id}`).deliveryFeeHold;
const retained = (h) => h.get('config/az_wallet')?.retainedDeliveryFees || 0;

// Commande marketplace wallet récupérée par dA (client 4500, vendeur 5000, dA 900).
async function pickedUpMarketplace(h = world(), method = 'wallet') {
  const id = await h.marketplace({ paymentMethod: method });
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  return { h, id };
}
async function pickedUpBoutique(h = world()) {
  await h.call('payBoutique', 'c1', PAY);
  const id = h.keys('orders/')[0].split('/')[1];
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  return { h, id };
}

// ───────────────────────────── annulation après récupération ─────────────────────────────
test('marketplace wallet annulée APRÈS récupération : produits rendus, frais retenus, commission non rendue, vendeur repris', async () => {
  const { h, id } = await pickedUpMarketplace();
  await h.call('cancel', 'c1', { orderId: id });
  assert.equal(h.w('clients/c1'), 4500 + 5000); // produits seuls
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.w('livreurs/dA'), 900); // commission non rendue tant que les frais sont retenus
  assert.deepEqual(
    { amount: hold(h, id).amount, status: hold(h, id).status, driverId: hold(h, id).driverId },
    { amount: 500, status: 'pending_admin_review', driverId: 'dA' });
  assert.equal(h.get(`orders/${id}`).commissionStatus, 'charged');
  // Conservation : 11000 au départ − 100 de commission = wallets + frais retenus.
  assert.equal(h.totalMoney() + hold(h, id).amount, 11000 - 100);
  // Rejeu : aucune seconde opération.
  await assert.rejects(() => h.call('cancel', 'c1', { orderId: id }));
  assert.equal(h.w('clients/c1'), 9500);
});

test('boutique wallet annulée APRÈS récupération : produits rendus, frais retenus, commande boutique remboursée', async () => {
  const { h, id } = await pickedUpBoutique();
  await h.call('cancel', 'c1', { orderId: id });
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], [9500, 0, 900]);
  assert.equal(hold(h, id).amount, 500);
  const bo = h.get(h.keys('boutique_orders/')[0]);
  assert.equal(bo.status, 'refunded');
  assert.equal(bo.feeRefunded, false);
  assert.equal(h.totalMoney() + 500, 11000 - 100);
});

test('paiement cash annulé après récupération : rien payé, rien retenu, commission rendue', async () => {
  const { h, id } = await pickedUpMarketplace(world(), 'cash');
  await h.call('cancel', 'c1', { orderId: id });
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.get(`orders/${id}`).deliveryFeeHold, undefined);
  assert.equal(h.w('livreurs/dA'), 1000);
});

test('commande historique annulée après récupération : comportement inchangé (remboursement du budget, pas de retenue)', async () => {
  const h = world({
    'orders/old': { clientId: 'c1', status: 'picked_up', paymentMethod: 'wallet', budget: 5000, isPaid: true,
      sellerId: 's1', sellerType: 'seller' },
    'clients/c1': { wallet: 0 }, 'sellers/s1': { wallet: 5000 },
  });
  await h.call('cancel', 'c1', { orderId: 'old' });
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1')], [5000, 0]);
  assert.equal(h.get('orders/old').deliveryFeeHold, undefined);
});

// ───────────────────────────── décision sur les frais retenus ─────────────────────────────
test('resolveFeeHold refundClient (faute du livreur/AZ) : frais rendus au client, commission rendue, une seule fois', async () => {
  const { h, id } = await pickedUpMarketplace();
  await h.call('cancel', 'c1', { orderId: id });
  const r = await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'refundClient' });
  assert.equal(r.decision, 'refundClient');
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(hold(h, id).status, 'resolved');
  assert.equal(h.totalMoney(), 11000 - 0); // la commission AZ est rendue : plus rien retenu
  // Rejeu et décision contraire : aucun effet.
  const again = await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'refundClient' });
  assert.equal(again.replay, true);
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'payDriver' });
  assert.deepEqual([h.w('clients/c1'), h.w('livreurs/dA')], [10000, 1000]);
});

test('resolveFeeHold payDriver : livreur rémunéré des frais (commission conservée), commission AZ enregistrée une fois', async () => {
  const { h, id } = await pickedUpMarketplace();
  await h.call('cancel', 'c1', { orderId: id });
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'payDriver' });
  assert.equal(h.w('livreurs/dA'), 900 + 500); // net +400 comme une livraison normale
  assert.equal(h.w('clients/c1'), 9500);
  assert.equal(h.commissionsLogged(), 100);
  assert.equal(h.get('config/az_wallet').totalCommissions, 100);
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'payDriver' });
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'refundClient' });
  assert.equal(h.w('livreurs/dA'), 1400);
  assert.equal(h.w('clients/c1'), 9500);
  assert.equal(h.commissionsLogged(), 100);
  assert.equal(h.totalMoney(), 10900); // = 11000 − commission AZ 100 (les 500 sont versés)
});

test('resolveFeeHold retain : AZ garde les frais, commission rendue, rien d’autre ne bouge', async () => {
  const { h, id } = await pickedUpMarketplace();
  await h.call('cancel', 'c1', { orderId: id });
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'retain' });
  assert.deepEqual([h.w('clients/c1'), h.w('livreurs/dA')], [9500, 1000]);
  assert.equal(retained(h), 500);
  assert.equal(h.totalMoney() + retained(h), 11000);
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'retain' });
  assert.equal(retained(h), 500);
});

test('resolveFeeHold : réservé au super-admin, justification obligatoire, décision valide, frais existants', async () => {
  const { h, id } = await pickedUpMarketplace();
  await h.call('cancel', 'c1', { orderId: id });
  const bad = (uid, data) => h.call('adminBilling', uid, { justification: 'Examen du dossier par AZ', ...data });
  await assert.rejects(() => bad('c1', { action: 'resolveFeeHold', orderId: id, decision: 'refundClient' }),
    (e) => e.code === 'permission-denied');
  await assert.rejects(() => bad('dA', { action: 'resolveFeeHold', orderId: id, decision: 'payDriver' }),
    (e) => e.code === 'permission-denied');
  await assert.rejects(() => h.call('adminBilling', 'root', { action: 'resolveFeeHold', orderId: id, decision: 'retain', justification: 'ok' }),
    (e) => e.code === 'invalid-argument');
  await assert.rejects(() => bad('root', { action: 'resolveFeeHold', orderId: id, decision: 'gift' }),
    (e) => e.code === 'invalid-argument');
  await assert.rejects(() => bad('root', { action: 'resolveFeeHold', orderId: 'inexistante', decision: 'retain' }),
    (e) => e.code === 'not-found');
  assert.equal(hold(h, id).status, 'pending_admin_review');
  assert.deepEqual([h.w('clients/c1'), h.w('livreurs/dA')], [9500, 900]);
});

test('resolveFeeHold sur une commande sans frais retenus : refusé (pas de paiement fictif)', async () => {
  const h = world();
  const id = await h.marketplace();
  await assert.rejects(() => ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'payDriver' }),
    (e) => e.code === 'failed-precondition');
  assert.equal(h.w('livreurs/dA'), 1000);
});

// ───────────────────────────── livraison abandonnée ─────────────────────────────
test('livraison marketplace abandonnée AVANT récupération (acceptée) : clôture admin = remboursement intégral, commission rendue', async () => {
  const h = world();
  const id = await h.marketplace();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  const r = await ADMIN(h, { action: 'closeStuckDelivery', orderId: id });
  assert.equal(r.clientRefund, 5500);
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], [10000, 0, 1000]);
  assert.equal(h.get(`orders/${id}`).status, 'cancelled');
  assert.equal(h.get(`orders/${id}`).adminReview.action, 'closeStuckDelivery');
  await assert.rejects(() => ADMIN(h, { action: 'closeStuckDelivery', orderId: id }), (e) => e.code === 'failed-precondition');
  assert.equal(h.w('clients/c1'), 10000);
});

test('livraison abandonnée APRÈS récupération : clôture admin = produits rendus + frais retenus ; décision ensuite', async () => {
  const { h, id } = await pickedUpMarketplace();
  const r = await ADMIN(h, { action: 'closeStuckDelivery', orderId: id });
  assert.deepEqual([r.clientRefund, r.feeHeld], [5000, 500]);
  assert.equal(hold(h, id).status, 'pending_admin_review');
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'refundClient' });
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('livreurs/dA'), 1000);
});

test('livraison abandonnée après récupération par faute du livreur : clôture avec refundFee → tout est rendu, aucune retenue', async () => {
  const { h, id } = await pickedUpMarketplace();
  const r = await ADMIN(h, { action: 'closeStuckDelivery', orderId: id, refundFee: true });
  assert.deepEqual([r.clientRefund, r.feeHeld], [5500, 0]);
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], [10000, 0, 1000]);
  assert.equal(h.get(`orders/${id}`).deliveryFeeHold, undefined);
  assert.equal(h.totalMoney(), 11000);
});

test('clôture d’une livraison déjà livrée : refusée (aucune annulation automatique d’une livraison terminée)', async () => {
  const { h, id } = await pickedUpMarketplace();
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  const snap = [h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')];
  await assert.rejects(() => ADMIN(h, { action: 'closeStuckDelivery', orderId: id }), (e) => e.code === 'failed-precondition');
  assert.deepEqual([h.w('clients/c1'), h.w('sellers/s1'), h.w('livreurs/dA')], snap);
  assert.equal(h.get(`orders/${id}`).status, 'delivered');
});

test('clôture : refusée hors Marketplace/Boutique', async () => {
  const h = world({ 'orders/x': { clientId: 'c1', status: 'accepted', driverId: 'dA', budget: 500, paymentMethod: 'cash' } });
  await assert.rejects(() => ADMIN(h, { action: 'closeStuckDelivery', orderId: 'x' }), (e) => e.code === 'failed-precondition');
});

// ───────────────────────────── remboursement boutique administratif ─────────────────────────────
test('boutique abandonnée (récupérée) : clôture → produits rendus + frais retenus → décision ; pas de double remboursement', async () => {
  const { h, id } = await pickedUpBoutique();
  await ADMIN(h, { action: 'closeStuckDelivery', orderId: id });
  assert.equal(h.get(h.keys('boutique_orders/')[0]).status, 'refunded');
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  // La commande boutique est déjà remboursée : ni remboursement admin, ni remboursement 48 h.
  await assert.rejects(() => ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId }), (e) => e.code === 'failed-precondition');
  const key = h.keys('boutique_orders/')[0];
  h.set(key, { ...h.get(key), deliveryDeadline: { toMillis: () => Date.now() - 1000 } });
  await assert.rejects(() => h.call('refund', 'c1', { orderId: boId }), (e) => e.code === 'failed-precondition');
  await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'refundClient' });
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.totalMoney(), 11000);
});

test('boutique : refundBoutiqueOrder refusé tant que la livraison n’est pas close, puis accepté une seule fois', async () => {
  const h = world();
  await h.call('payBoutique', 'c1', PAY);
  const id = h.keys('orders/')[0].split('/')[1];
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  await assert.rejects(() => ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId }), (e) => e.code === 'failed-precondition');
  // La livraison tombe sans livreur (annulée par expiration), la commande boutique reste « payée ».
  h.set(`orders/${id}`, { ...h.get(`orders/${id}`), status: 'cancelled' });
  const r = await ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId });
  assert.equal(r.amount, 5500);
  assert.equal(h.w('clients/c1'), 10000 + 0);
  assert.equal(h.w('sellers/s1'), 0);
  await assert.rejects(() => ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId }), (e) => e.code === 'failed-precondition');
  assert.equal(h.w('clients/c1'), 10000);
});

test('boutique historique (sans montants explicites) : clôture puis remboursement admin = prix des produits seulement', async () => {
  const h = world();
  h.set('config/billing', { ...(h.get('config/billing') || {}), legacyPartnerAcceptance: 'no_commission' });
  await h.call('payBoutique', 'c1', { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5 }); // ancienne appli
  const id = h.keys('orders/')[0].split('/')[1];
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await ADMIN(h, { action: 'closeStuckDelivery', orderId: id });
  const r = await ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId });
  assert.equal(r.amount, 5000);
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.w('livreurs/dA'), 1000); // commission rendue à la clôture
  assert.equal(h.get(`orders/${id}`).deliveryFeeHold, undefined);
});

test('boutique : remboursement admin refusé si des frais sont encore retenus ou si la livraison est terminée', async () => {
  const { h, id } = await pickedUpBoutique();
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  await assert.rejects(() => ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId }), (e) => e.code === 'failed-precondition');
  assert.equal(h.w('clients/c1'), 4500);
  assert.equal(h.w('sellers/s1'), 5000);
});

test('boutique : plafonné au solde du vendeur (jamais de solde négatif) lors du remboursement administratif', async () => {
  const h = world();
  await h.call('payBoutique', 'c1', PAY);
  const id = h.keys('orders/')[0].split('/')[1];
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  h.set(`orders/${id}`, { ...h.get(`orders/${id}`), status: 'cancelled' });
  h.set('sellers/s1', { ...h.get('sellers/s1'), wallet: 1200 });
  await ADMIN(h, { action: 'refundBoutiqueOrder', orderId: boId });
  assert.equal(h.w('sellers/s1'), 0);
});

// ───────────────────────────── transferts maintenus refusés ─────────────────────────────
test('les transferts entre livreurs restent refusés pour Marketplace et Boutique (PARTNER_ORDER_REVIEW)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'driverTransfer.js'), 'utf8');
  assert.match(src, /PARTNER_ORDER_REVIEW/);
  assert.match(src, /seller/);
  assert.match(src, /boutique/);
});

// ───────────────────────────── rejeu et conservation globale ─────────────────────────────
test('rejeu en rafale : annulation, clôture et décisions répétées ne créent ni ne perdent aucun FCFA', async () => {
  const { h, id } = await pickedUpMarketplace();
  // Avant l'annulation, les 500 de frais payés par le client sont en transit (dans aucun wallet).
  const start = h.totalMoney() + 500; // = 11000 − 100 de commission déjà encaissée
  await h.call('cancel', 'c1', { orderId: id });
  for (let i = 0; i < 3; i += 1) {
    await h.call('cancel', 'c1', { orderId: id }).catch(() => {});
    await ADMIN(h, { action: 'closeStuckDelivery', orderId: id }).catch(() => {});
  }
  assert.equal(h.totalMoney() + hold(h, id).amount, start);
  for (let i = 0; i < 3; i += 1) {
    await ADMIN(h, { action: 'resolveFeeHold', orderId: id, decision: 'payDriver' });
  }
  assert.equal(h.totalMoney(), 10900);
  assert.equal(h.commissionsLogged(), 100);
});
