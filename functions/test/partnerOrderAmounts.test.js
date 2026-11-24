'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { PARTNER_AMOUNTS_VERSION, buildPartnerAmounts, readPartnerAmounts, partnerBreakdown } = require('../partnerOrderAmounts');
const { readAmounts } = require('../orderAmounts');

test('buildPartnerAmounts : produits + livraison = total, budget = livraison, version 2', () => {
  const a = buildPartnerAmounts(2500, 700);
  assert.deepEqual(a, { amountsVersion: 2, productAmount: 2500, deliveryFee: 700, totalAmount: 3200, budget: 700 });
  assert.equal(PARTNER_AMOUNTS_VERSION, 2);
});

test('buildPartnerAmounts : montants invalides refusés', () => {
  for (const [p, d] of [[0, 500], [-1, 500], [1000, 0], [1000.5, 500], ['1000', 500], [1000, NaN], [Number.MAX_SAFE_INTEGER, 5]]) {
    assert.throws(() => buildPartnerAmounts(p, d), undefined, `${p}/${d}`);
  }
});

test('readPartnerAmounts : lit une commande cohérente, rejette tout le reste (= commande historique)', () => {
  const ok = { ...buildPartnerAmounts(1800, 500) };
  assert.deepEqual(readPartnerAmounts(ok), { productAmount: 1800, deliveryFee: 500, totalAmount: 2300 });
  assert.equal(readPartnerAmounts(null), null);
  assert.equal(readPartnerAmounts({}), null);
  assert.equal(readPartnerAmounts({ ...ok, amountsVersion: 1 }), null);
  assert.equal(readPartnerAmounts({ ...ok, totalAmount: 9999 }), null);
  assert.equal(readPartnerAmounts({ ...ok, budget: 9999 }), null);
  assert.equal(readPartnerAmounts({ ...ok, productAmount: '1800' }), null);
  assert.equal(readPartnerAmounts({ ...ok, deliveryFee: 0, totalAmount: 1800, budget: 0 }), null);
});

test('une commande version 2 n\'est jamais lue comme Marketplace/Boutique (version 1) et inversement', () => {
  const v2 = buildPartnerAmounts(1800, 500);
  assert.equal(readAmounts(v2), null);
  assert.equal(readPartnerAmounts({ amountsVersion: 1, productAmount: 1800, deliveryFee: 500, totalAmount: 2300, budget: 500 }), null);
});

test('commande historique restaurant/boulangerie (sans version) : lecture nulle', () => {
  assert.equal(readPartnerAmounts({ budget: 2500, sellerType: 'restaurant' }), null);
  assert.equal(readPartnerAmounts({ budget: 500, itemsAmount: 1800, totalAmount: 2300, sellerType: 'boulangerie' }), null);
});

test('partnerBreakdown : quatre montants séparés, commission limitée aux frais, aucune commission sur les produits', () => {
  const a = buildPartnerAmounts(3000, 700);
  assert.deepEqual(partnerBreakdown(a, { commission: 100 }), {
    clientPays: 3700, partnerDue: 3000, driverGross: 700, azCommission: 100, driverNet: 600,
  });
  // Conservation : ce que paie le client = partenaire + livreur brut.
  const b = partnerBreakdown(a, { commission: 200 });
  assert.equal(b.clientPays, b.partnerDue + b.driverGross);
  assert.equal(b.driverNet + b.azCommission, b.driverGross);
});

test('partnerBreakdown : commission supérieure aux frais ou invalide refusée', () => {
  const a = buildPartnerAmounts(3000, 500);
  assert.throws(() => partnerBreakdown(a, { commission: 501 }));
  assert.throws(() => partnerBreakdown(a, { commission: -1 }));
  assert.throws(() => partnerBreakdown(a, { commission: 1.5 }));
  assert.throws(() => partnerBreakdown(null));
  assert.equal(partnerBreakdown(a, { commission: 500 }).driverNet, 0);
});

test('partnerBreakdown cash : le livreur encaisse le total et doit reverser les produits', () => {
  const a = buildPartnerAmounts(3000, 500);
  const c = partnerBreakdown(a, { commission: 100, paymentMethod: 'cash' });
  assert.equal(c.cashCollectedByDriver, 3500);
  assert.equal(c.cashToRemitToPartner, 3000);
  assert.equal(c.cashCollectedByDriver - c.cashToRemitToPartner, c.driverGross);
});

test('partnerPickupBlock : v2 refuse tout sauf ready ; les autres commandes ne sont jamais bloquées', () => {
  const { partnerPickupBlock } = require('../partnerOrderAmounts');
  for (const s of [undefined, null, '', 'preparing', 'accepted', 'READY']) {
    assert.equal(partnerPickupBlock({ amountsVersion: 2, sellerStatus: s }).code, 'failed-precondition');
  }
  assert.equal(partnerPickupBlock({ amountsVersion: 2, sellerStatus: 'ready' }), null);
  for (const o of [{ sellerStatus: 'preparing' }, { amountsVersion: 1 }, { amountsVersion: '2' }, {}, null]) {
    assert.equal(partnerPickupBlock(o), null);
  }
});
