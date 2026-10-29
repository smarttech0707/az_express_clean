'use strict';

// Stock boutique : décrémenté à la création ; JAMAIS restitué automatiquement lors d'une
// annulation ou d'un remboursement (le produit peut être chez le client) ; restitué
// seulement sur confirmation administrative (non-livraison constatée ou retour confirmé).

const test = require('node:test');
const assert = require('node:assert/strict');
const { world, photo } = require('./billingWorld');

const PAY = { productId: 'b1', qty: 2, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 10500 };
const stock = (h) => h.get('boutique_products/b1').stock;
const ADMIN = (h, data) => h.call('adminBilling', 'root', { justification: 'constat administratif', ...data });

async function paid() {
  const h = world({ 'clients/c1': { wallet: 20000 } });
  await h.call('payBoutique', 'c1', PAY);
  const id = h.keys('orders/')[0].split('/')[1];
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  return { h, id, boId };
}

test('création : le stock est décrémenté de la quantité commandée (wallet et cash)', async () => {
  const { h } = await paid();
  assert.equal(stock(h), 8);
  const c = world({ 'clients/c1': { wallet: 20000 } });
  await c.call('payBoutiqueCash', 'c1', PAY);
  assert.equal(stock(c), 8);
});

test('annulation avant récupération : client remboursé, stock NON restitué automatiquement', async () => {
  const { h, id, boId } = await paid();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  await h.call('cancel', 'c1', { orderId: id });
  assert.equal(h.get(`boutique_orders/${boId}`).status, 'refunded');
  assert.equal(h.w('clients/c1'), 20000);
  assert.equal(stock(h), 8);
});

test('annulation après récupération : stock inchangé (le produit est parti avec le livreur)', async () => {
  const { h, id } = await paid();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await h.call('cancel', 'c1', { orderId: id });
  assert.equal(stock(h), 8);
});

test('clôture administrative après récupération : produits remboursés, jamais de remise en stock automatique', async () => {
  const { h, id, boId } = await paid();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await ADMIN(h, { action: 'closeStuckDelivery', orderId: id });
  assert.equal(h.get(`boutique_orders/${boId}`).status, 'refunded'); // la clôture a remboursé les produits
  assert.equal(stock(h), 8);
});

test('confirmStockReturn non_delivery : annulée avant récupération → stock restitué une seule fois (rejeu sans effet)', async () => {
  const { h, id, boId } = await paid();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  await h.call('cancel', 'c1', { orderId: id });
  const r = await ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'non_delivery' });
  assert.equal(r.restored, 2);
  assert.equal(stock(h), 10);
  const again = await ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'non_delivery' });
  assert.equal(again.replay, true);
  assert.equal(stock(h), 10);
  assert.equal(h.get(`boutique_orders/${boId}`).stockReturn.status, 'restored');
});

test('confirmStockReturn : colis possiblement récupéré → non_delivery refusé, product_returned accepté', async () => {
  const { h, id, boId } = await paid();
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.set(`orders/${id}`, { ...h.get(`orders/${id}`), pickedUpAt: 1 });
  h.pickUp(id);
  await ADMIN(h, { action: 'closeStuckDelivery', orderId: id });
  assert.equal(h.get(`boutique_orders/${boId}`).status, 'refunded'); // la clôture a remboursé les produits
  await assert.rejects(() => ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'non_delivery' }),
    (e) => e.code === 'failed-precondition');
  assert.equal(stock(h), 8);
  await ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'product_returned' });
  assert.equal(stock(h), 10);
});

test('confirmStockReturn refusé : commande payée non remboursée, livrée, livraison ouverte, motif invalide', async () => {
  const { h, id, boId } = await paid();
  await assert.rejects(() => ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'product_returned' }),
    (e) => e.code === 'failed-precondition'); // payée, ni remboursée ni annulée
  await assert.rejects(() => ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'x' }),
    (e) => e.code === 'invalid-argument');
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  h.pickUp(id);
  await h.call('deliver', 'dA', { orderId: id, deliveryPhotoUrl: photo });
  await assert.rejects(() => ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'product_returned' }),
    (e) => e.code === 'failed-precondition'); // produit livré au client, non remboursé
  assert.equal(stock(h), 8);
});

test('confirmStockReturn : commande cash dont la livraison est annulée avant récupération', async () => {
  const h = world({ 'clients/c1': { wallet: 20000 } });
  await h.call('payBoutiqueCash', 'c1', PAY);
  const id = h.keys('orders/')[0].split('/')[1];
  const boId = h.keys('boutique_orders/')[0].split('/')[1];
  h.assign(id);
  await h.call('accept', 'dA', { orderId: id });
  await h.call('cancel', 'c1', { orderId: id });
  await ADMIN(h, { action: 'confirmStockReturn', orderId: boId, reason: 'non_delivery' });
  assert.equal(stock(h), 10);
});

test('confirmStockReturn : réservé au super-admin, justification obligatoire', async () => {
  const { h, boId } = await paid();
  await assert.rejects(() => h.call('adminBilling', 'c1', { action: 'confirmStockReturn', orderId: boId,
    reason: 'non_delivery', justification: 'constat administratif' }), (e) => e.code === 'permission-denied');
  await assert.rejects(() => h.call('adminBilling', 'root', { action: 'confirmStockReturn', orderId: boId,
    reason: 'non_delivery', justification: 'court' }), (e) => e.code === 'invalid-argument');
});
