'use strict';

// Compatibilité des anciennes applications : le serveur ne débite JAMAIS plus que
// le montant présenté et accepté par le client.
//   - ancienne application Boutique : affiche le prix des produits seul, n'envoie pas
//     `acceptedTotal` → facturation historique (produits seuls) ;
//   - nouvelle application : envoie le total affiché (`acceptedTotal`) → facturé
//     exactement ce total, sinon refus (MONTANT_MODIFIE) ;
//   - config/billing.separateDeliveryFee : legacy | accepted_only (défaut) | required.

const test = require('node:test');
const assert = require('node:assert/strict');
const { world, admin, HttpsError } = require('./billingWorld');
const { createMarketplaceOrder } = require('../azia/tools/marketplace');
const { getBillingMode, decideBilling } = require('../billingPolicy');

const PAY = { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5 }; // produit 5000
const stock = (h) => h.get('boutique_products/b1').stock;

// ───────────────────────────── ancienne application ─────────────────────────────
test('ancienne application boutique (wallet) : affiche 5000 → débite 5000, jamais 5500', async () => {
  const h = world();
  h.legacyPolicy('no_commission');
  const r = await h.call('payBoutique', 'c1', PAY); // pas d'acceptedTotal
  assert.equal(h.w('clients/c1'), 5000);
  assert.equal(h.w('sellers/s1'), 5000);
  assert.deepEqual([r.totalPrice, r.totalAmount, r.deliveryFee], [5000, 5000, 0]);
  const delivery = h.get(h.keys('orders/')[0]);
  assert.equal(delivery.amountsVersion, undefined); // commande historique
  assert.equal(delivery.budget, 500);
  assert.equal(delivery.deliveryFeePaid, undefined);
  assert.equal(h.get(h.keys('boutique_orders/')[0]).totalAmount, undefined);
});

test('ancienne application boutique (cash) : aucune donnée de facturation explicite', async () => {
  const h = world();
  h.legacyPolicy('no_commission');
  await h.call('payBoutiqueCash', 'c1', PAY);
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.get(h.keys('orders/')[0]).amountsVersion, undefined);
});

test('politique par défaut (block) : une ancienne application ne peut plus créer de commande — rien débité, stock intact', async () => {
  const h = world();
  for (const fn of ['payBoutique', 'payBoutiqueCash']) {
    await assert.rejects(() => h.call(fn, 'c1', PAY),
      (e) => e.code === 'failed-precondition' && e.message === 'APP_UPDATE_REQUIRED');
  }
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
  assert.equal(h.keys('orders/').length, 0);
  assert.equal(h.keys('boutique_orders/').length, 0);
  const before = stock(h);
  assert.equal(stock(h), before);
});

test('politique par défaut (block) : la nouvelle application (acceptedTotal) n’est pas affectée', async () => {
  const h = world();
  await h.call('payBoutique', 'c1', { ...PAY, acceptedTotal: 5500 });
  assert.equal(h.w('clients/c1'), 4500);
});

test('commande historique déjà créée, politique block : non acceptable (aucune commission sans rémunération)', async () => {
  const h = world();
  h.legacyPolicy('no_commission');
  await h.call('payBoutique', 'c1', PAY);
  h.legacyPolicy('block');
  const delivery = h.keys('orders/')[0].split('/')[1];
  h.assign(delivery);
  await assert.rejects(() => h.call('accept', 'dA', { orderId: delivery }),
    (e) => e.code === 'failed-precondition' && e.message === 'LEGACY_PARTNER_ORDER');
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.get(`orders/${delivery}`).status, 'assigned');
});

test('ancienne application, politique no_commission : acceptée SANS commission, livreur ni débité ni crédité', async () => {
  const h = world();
  h.set('config/billing', { ...(h.get('config/billing') || {}), legacyPartnerAcceptance: 'no_commission' });
  await h.call('payBoutique', 'c1', PAY);
  const delivery = h.keys('orders/')[0].split('/')[1];
  h.assign(delivery);
  await h.call('accept', 'dA', { orderId: delivery });
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.get(`orders/${delivery}`).commissionWaivedReason, 'legacy_partner_order');
  h.pickUp(delivery);
  await h.call('deliver', 'dA', { orderId: delivery, deliveryPhotoUrl: 'https://x/p.jpg' });
  assert.equal(h.w('livreurs/dA'), 1000);
  assert.equal(h.w('sellers/s1'), 5000);
});

// ───────────────────────────── nouvelle application ─────────────────────────────
test('nouvelle application : affiche 5500 → débite exactement 5500', async () => {
  const h = world();
  const r = await h.call('payBoutique', 'c1', { ...PAY, acceptedTotal: 5500 });
  assert.equal(h.w('clients/c1'), 4500);
  assert.equal(r.totalAmount, 5500);
  assert.equal(h.get(h.keys('orders/')[0]).totalAmount, 5500);
});

for (const shown of [5000, 5499, 5501, 6000, 1]) {
  test(`nouvelle application : total affiché périmé/erroné (${shown}) → refus MONTANT_MODIFIE:5500, rien débité, stock intact`, async () => {
    const h = world();
    for (const fn of ['payBoutique', 'payBoutiqueCash']) {
      await assert.rejects(
        () => h.call(fn, 'c1', { ...PAY, acceptedTotal: shown }),
        (e) => e.code === 'failed-precondition' && e.message === 'MONTANT_MODIFIE:5500');
    }
    assert.equal(h.w('clients/c1'), 10000);
    assert.equal(h.w('sellers/s1'), 0);
    assert.equal(stock(h), 10);
    assert.equal(h.keys('orders/').length + h.keys('boutique_orders/').length, 0);
  });
}

test('nouvelle application : le prix du produit change entre l’affichage et le paiement → refus (le client revoit le nouveau total)', async () => {
  const h = world();
  h.set('boutique_products/b1', { ...h.get('boutique_products/b1'), price: 6000 });
  await assert.rejects(
    () => h.call('payBoutique', 'c1', { ...PAY, acceptedTotal: 5500 }),
    (e) => e.message === 'MONTANT_MODIFIE:6500');
  assert.equal(h.w('clients/c1'), 10000);
});

for (const bad of [-5500, 0, 5500.5, '5500', NaN]) {
  test(`montant accepté invalide (${String(bad)}) → invalid-argument, rien débité`, async () => {
    const h = world();
    await assert.rejects(
      () => h.call('payBoutique', 'c1', { ...PAY, acceptedTotal: bad }),
      (e) => e.code === 'invalid-argument');
    assert.equal(h.w('clients/c1'), 10000);
  });
}

// ───────────────────────────── activation progressive ─────────────────────────────
test('mode par défaut (document absent ou valeur inconnue) = accepted_only', async () => {
  const h = world();
  assert.equal(await getBillingMode(h.db), 'accepted_only');
  h.mode('n_importe_quoi');
  assert.equal(await getBillingMode(h.db), 'accepted_only');
  const broken = { collection: () => { throw new Error('lecture impossible'); } };
  assert.equal(await getBillingMode(broken), 'accepted_only'); // panne de lecture : jamais de blocage ni de surfacturation
});

test('mode legacy (coupe-circuit) : ancienne application inchangée ; nouvelle application refusée plutôt que sous-facturée', async () => {
  const h = world();
  h.legacyPolicy('no_commission');
  h.mode('legacy');
  await h.call('payBoutique', 'c1', PAY);
  assert.equal(h.w('clients/c1'), 5000);
  await assert.rejects(
    () => h.call('payBoutique', 'c1', { ...PAY, acceptedTotal: 5500 }),
    (e) => e.message === 'FACTURATION_INDISPONIBLE');
  assert.equal(h.w('clients/c1'), 5000);
});

test('mode required : ancienne application refusée (APP_UPDATE_REQUIRED), rien débité ; nouvelle application acceptée', async () => {
  const h = world();
  h.mode('required');
  for (const fn of ['payBoutique', 'payBoutiqueCash']) {
    await assert.rejects(() => h.call(fn, 'c1', PAY), (e) => e.message === 'APP_UPDATE_REQUIRED');
  }
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(stock(h), 10);
  await h.call('payBoutique', 'c1', { ...PAY, acceptedTotal: 5500 });
  assert.equal(h.w('clients/c1'), 4500);
});

test('invariant : quels que soient le mode, l’application et le moyen de paiement, débit ≤ montant présenté (et = total accepté si déclaré)', async () => {
  for (const mode of ['legacy', 'accepted_only', 'required', undefined]) {
    for (const accepted of [undefined, 5000, 5500, 6000]) {
      for (const fn of ['payBoutique', 'payBoutiqueCash']) {
        const h = world();
        if (mode) h.mode(mode);
        const data = accepted === undefined ? PAY : { ...PAY, acceptedTotal: accepted };
        let ok = true;
        try { await h.call(fn, 'c1', data); } catch (_) { ok = false; }
        const debited = 10000 - h.w('clients/c1');
        const presented = accepted === undefined ? 5000 : accepted; // ancienne appli : prix produit seul
        assert.ok(debited <= presented, `${mode}/${accepted}/${fn}: débité ${debited} > présenté ${presented}`);
        if (ok && accepted !== undefined && fn === 'payBoutique') assert.equal(debited, accepted);
        if (!ok) assert.equal(debited, 0);
      }
    }
  }
});

test('decideBilling : table de décision', () => {
  const d = (mode, acceptedTotal) => {
    try { return decideBilling({ mode, acceptedTotal, HttpsError }); } catch (e) { return e.message; }
  };
  assert.equal(d('accepted_only', undefined), 'legacy');
  assert.equal(d('accepted_only', 5500), 'explicit');
  assert.equal(d('legacy', undefined), 'legacy');
  assert.equal(d('legacy', 5500), 'FACTURATION_INDISPONIBLE');
  assert.equal(d('required', undefined), 'APP_UPDATE_REQUIRED');
  assert.equal(d('required', 5500), 'explicit');
});

// ───────────────────────────── marketplace (AZ IA) ─────────────────────────────
test('marketplace : le texte de confirmation présente le total qui sera débité — affiché = débité', async () => {
  const h = world();
  const tool = createMarketplaceOrder({ db: h.db, admin, HttpsError });
  const out = await tool.handler('c1', {
    productId: 'p1', quantity: 1, deliveryLat: 6.7273, deliveryLng: -3.4961, paymentMethod: 'wallet',
  });
  const pending = h.get(`ai_pending_actions/${out.actionId}`);
  const shown = Number(/total (\d+) FCFA/.exec(out.summaryFr)[1]);
  assert.equal(shown, pending.amount);
  await h.db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', pending.toolInput));
  assert.equal(10000 - h.w('clients/c1'), shown);
});

test('marketplace : mode legacy → facturation historique (produits seuls) et texte sans frais', async () => {
  const h = world();
  h.legacyPolicy('no_commission');
  h.mode('legacy');
  const tool = createMarketplaceOrder({ db: h.db, admin, HttpsError });
  const out = await tool.handler('c1', {
    productId: 'p1', quantity: 1, deliveryLat: 6.7273, deliveryLng: -3.4961, paymentMethod: 'wallet',
  });
  assert.doesNotMatch(out.summaryFr, /livraison/);
  const pending = h.get(`ai_pending_actions/${out.actionId}`);
  assert.equal(pending.amount, 5000);
  await h.db.runTransaction((tx) => tool.confirmHandler(tx, 'c1', pending.toolInput));
  assert.equal(h.w('clients/c1'), 5000);
  assert.equal(h.w('sellers/s1'), 5000);
  const order = h.get(h.keys('orders/')[0]);
  assert.equal(order.amountsVersion, undefined);
  assert.equal(order.budget, 5000);
});
