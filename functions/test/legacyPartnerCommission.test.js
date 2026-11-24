'use strict';

// Conservation financière : aucune commission conservée par AZ sans rémunération
// correspondante du livreur (commandes Marketplace/Boutique « historiques »).

const test = require('node:test');
const assert = require('node:assert/strict');
const { world, photo } = require('./billingWorld');

const legacyOrder = (extra = {}) => ({
  clientId: 'c1', status: 'picked_up', driverId: 'dA', paymentMethod: 'wallet', budget: 5000, isPaid: true,
  sellerId: 's1', sellerType: 'seller', commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
  ...extra,
});
// dA a payé 200 à l'acceptation : 1000 − 200.
const seedAccepted = (order, extra = {}) => ({
  'orders/old': order, 'livreurs/dA': { wallet: 800, isOnline: true, isAvailable: false }, ...extra,
});

for (const method of ['wallet', 'cash']) {
  test(`course historique déjà acceptée (${method}) : la commission tracée est rendue, AZ ne garde rien`, async () => {
    const h = world(seedAccepted(legacyOrder({ paymentMethod: method, isPaid: method === 'wallet' })));
    const before = h.totalMoney();
    await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
    assert.equal(h.w('livreurs/dA'), 1000);
    assert.equal(h.totalMoney(), before + 200); // les 200 retenus par AZ reviennent dans les wallets
    const o = h.get('orders/old');
    assert.equal(o.commissionStatus, 'refunded');
    assert.equal(o.commissionRefundReason, 'legacy_partner_unremunerated');
    assert.equal(h.commissionsLogged(), 0);
  });
}

test('rejeu de la livraison : aucun second remboursement de commission', async () => {
  const h = world(seedAccepted(legacyOrder()));
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  await assert.rejects(() => h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo }));
  assert.equal(h.w('livreurs/dA'), 1000);
});

test('commission payée par un autre livreur (transfert) : c’est le payeur d’origine qui est remboursé', async () => {
  const h = world(seedAccepted(legacyOrder({ commissionPayerId: 'dB' }), {
    'livreurs/dB': { wallet: 800, isOnline: true },
  }));
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dB'), 1000);
  assert.equal(h.w('livreurs/dA'), 800);
});

test('commission non tracée : rien n’est rendu automatiquement (aucune création d’argent) et la commande est signalée', async () => {
  const order = legacyOrder();
  delete order.commissionStatus; delete order.commissionPayerId; delete order.commissionAmount;
  const h = world(seedAccepted(order));
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 800);
  assert.equal(h.get('orders/old').legacyBillingReview.status, 'pending_admin_review');
});

test('payeur introuvable : aucun crédit fictif, la livraison aboutit', async () => {
  const h = world(seedAccepted(legacyOrder({ commissionPayerId: 'ghost' })));
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  assert.equal(h.get('orders/old').status, 'delivered');
  assert.equal(h.get('orders/old').commissionStatus, 'charged');
  assert.equal(h.get('livreurs/ghost'), undefined);
});

test('commission nulle tracée : aucun mouvement', async () => {
  const h = world(seedAccepted(legacyOrder({ commissionAmount: 0 })));
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 800);
});

test('commande à montants explicites : inchangée — commission conservée, livreur rémunéré des frais', async () => {
  const h = world();
  const id = await h.marketplace();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  assert.equal(h.w('livreurs/dA'), 900);
  h.pickUp(id);
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 1400);
  assert.equal(h.get(`orders/${id}`).commissionStatus, 'charged');
  assert.equal(h.commissionsLogged(), 100);
});

test('politique no_commission : acceptation puis livraison d’une commande historique = aucun mouvement pour le livreur', async () => {
  const h = world({ 'orders/old': legacyOrder({ status: 'assigned', commissionStatus: undefined,
    commissionPayerId: undefined, commissionAmount: undefined, pickupCityId: 'abengourou' }) });
  h.legacyPolicy('no_commission');
  await h.call('accept', 'dA', { orderId: 'old' });
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.get('orders/old').commissionWaivedReason, 'legacy_partner_order');
  h.pickUp('old');
  await h.call('deliver', 'dA', { orderId: 'old', deliveryPhotoUrl: photo });
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.commissionsLogged(), 0);
});

test('politique block (défaut) : acceptation refusée, course intacte et livreur non débité', async () => {
  const h = world({ 'orders/old': legacyOrder({ status: 'assigned', commissionStatus: undefined,
    commissionPayerId: undefined, commissionAmount: undefined, pickupCityId: 'abengourou' }) });
  await assert.rejects(() => h.call('accept', 'dA', { orderId: 'old' }), (e) => e.message === 'LEGACY_PARTNER_ORDER');
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.get('orders/old').status, 'assigned');
});

test('politique inconnue ou illisible → block', async () => {
  const h = world({ 'orders/old': legacyOrder({ status: 'assigned', commissionStatus: undefined,
    commissionPayerId: undefined, commissionAmount: undefined, pickupCityId: 'abengourou' }) });
  h.legacyPolicy('n_importe_quoi');
  await assert.rejects(() => h.call('accept', 'dA', { orderId: 'old' }), (e) => e.message === 'LEGACY_PARTNER_ORDER');
});

test('résolution administrative d’une commande historique bloquée : clôture et remboursement des produits, aucune commission retenue', async () => {
  const h = world({ 'orders/old': legacyOrder({ status: 'assigned', commissionStatus: undefined,
    commissionPayerId: undefined, commissionAmount: undefined, pickupCityId: 'abengourou' }),
  'sellers/s1': { wallet: 5000 }, 'clients/c1': { wallet: 0 } });
  const before = h.totalMoney();
  await h.call('adminBilling', 'root', { action: 'closeStuckDelivery', orderId: 'old', justification: 'ancienne commande bloquée' });
  assert.equal(h.get('orders/old').status, 'cancelled');
  assert.equal(h.w('clients/c1'), 5000);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.totalMoney(), before);
});
