'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF } = require('../partnerOrderQuote');
const { buildCreateOrderFromQuoteCF } = require('../deliveryQuote');
const { buildCreateCatalogOrderFromQuoteCF } = require('../catalogQuote');
const { PARTNER_LIMITS, parseItems, partnerRefusal, itemsFingerprint } = require('../partnerCatalog');
const { readPartnerAmounts } = require('../partnerOrderAmounts');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'TS' } } };
const auth = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });
const T0 = Date.UTC(2026, 10, 3, 12, 0, 0);
const PLACE = { lat: 6.7273, lng: -3.4961 };
const DEST = { lat: 6.7453, lng: -3.4961 };
const GEO = { pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' };

function world({ wallet = 20000, seed = {}, enabled = true } = {}) {
  const db = fakeDb({
    'clients/alice': { wallet, name: 'Alice Test', phone: '+2250000000001' },
    'clients/bob': { wallet: 9000 },
    'config/partnerOrdersV2': { pilotPartnerIds: ['r1', 'b1', 'nope'], creationOpen: true },
    'restaurants/r1': { name: 'Chez Test', lat: PLACE.lat, lng: PLACE.lng, isOpen: true },
    'restaurants/r1/menu/m1': { name: 'Attiéké poisson', price: 1500, available: true },
    'restaurants/r1/menu/m2': { name: 'Jus', price: 500 },
    'restaurants/r1/menu/m3': { name: 'Plat épuisé', price: 800, available: false },
    'boulangeries/b1': { name: 'Boulangerie Test', lat: PLACE.lat, lng: PLACE.lng, isActive: true, isOpen: true },
    'boulangeries/b1/menu_items/p1': { name: 'Baguette', price: 150, isAvailable: true },
    'boulangeries/b1/menu_items/p2': { name: 'Croissant', price: 300, isAvailable: true },
    'boulangeries/b1/menu_items/p3': { name: 'Brioche', price: 400, isAvailable: false },
    ...seed,
  });
  const audits = []; const limits = [];
  let clock = T0; let seq = 0; let geo = GEO;
  const deps = {
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async (uid, action, max, win) => { limits.push([uid, action, max, win]); },
    logAudit: async (a) => { audits.push(a); }, now: () => clock, isEnabled: () => enabled,
  };
  const quoteFn = buildQuotePartnerOrderCF({ ...deps, randomId: () => `quote-${++seq}` }).run;
  const orderFn = buildCreatePartnerOrderFromQuoteCF({ ...deps, newOrderId: () => `order-${++seq}`, resolveGeography: async () => geo }).run;
  return {
    db, audits, limits, store: db.store, deps,
    q: (data, uid = 'alice') => quoteFn({ auth: auth(uid), data }),
    o: (data, uid = 'alice') => orderFn({ auth: auth(uid), data }),
    qAs: (a, data) => quoteFn({ auth: a, data }),
    setClock: (ms) => { clock = ms; }, setGeo: (g) => { geo = g; },
  };
}
const wallet = (w, uid = 'alice') => w.store.get(`clients/${uid}`).wallet;
const ledger = (w, uid = 'alice') => [...w.store.keys()].filter((k) => k.startsWith(`clients/${uid}/wallet_transactions/`));
const orders = (w) => [...w.store.keys()].filter((k) => k.startsWith('orders/'));

const rReq = { sellerType: 'restaurant', sellerId: 'r1', items: [{ itemId: 'm1', qty: 2 }, { itemId: 'm2', qty: 1 }], destination: DEST };
const bReq = { sellerType: 'boulangerie', sellerId: 'b1', items: [{ itemId: 'p1', qty: 4 }, { itemId: 'p2', qty: 2 }], destination: DEST };
const create = (quote, req, extra = {}) => ({
  quoteId: quote.data.quoteId, paymentMethod: 'wallet', ...req, confirmedAmount: quote.data.total,
  deliveryAddress: 'Quartier Test, Abengourou', ...extra,
});

// ── Helpers purs ──────────────────────────────────────────────────────────

test('panier : canonique, trié, sans prix ; refus des doublons, quantités et identifiants invalides', () => {
  assert.deepEqual(parseItems([{ itemId: 'b', qty: 1, price: 1 }, { itemId: 'a', qty: 2 }]), [{ itemId: 'a', qty: 2 }, { itemId: 'b', qty: 1 }]);
  const code = (raw) => { try { parseItems(raw); } catch (e) { return e.code; } return null; };
  assert.equal(code([]), 'INVALID_ITEMS');
  assert.equal(code('x'), 'INVALID_ITEMS');
  assert.equal(code([{ itemId: 'a', qty: 1 }, { itemId: 'a', qty: 1 }]), 'DUPLICATE_ITEM');
  assert.equal(code([{ itemId: 'a', qty: 0 }]), 'INVALID_QUANTITY');
  assert.equal(code([{ itemId: 'a', qty: 1.5 }]), 'INVALID_QUANTITY');
  assert.equal(code([{ itemId: 'a', qty: PARTNER_LIMITS.maxQtyPerLine + 1 }]), 'QUANTITY_TOO_HIGH');
  assert.equal(code([{ itemId: 'a/b', qty: 1 }]), 'INVALID_ITEM');
  assert.equal(code(Array.from({ length: 31 }, (_, i) => ({ itemId: `i${i}`, qty: 1 }))), 'TOO_MANY_LINES');
});

test('partenaire : restaurant ouvert par défaut ; boulangerie doit être active ET ouverte ; horaires UTC ; suspendu refusé', () => {
  assert.equal(partnerRefusal('restaurant', { name: 'x' }, T0), null);
  assert.equal(partnerRefusal('restaurant', { isOpen: false }, T0).code, 'PARTNER_CLOSED');
  assert.equal(partnerRefusal('restaurant', { subscriptionStatus: 'suspended' }, T0).code, 'PARTNER_UNAVAILABLE');
  assert.equal(partnerRefusal('restaurant', null, T0).code, 'PARTNER_NOT_FOUND');
  assert.equal(partnerRefusal('boulangerie', { isActive: true }, T0).code, 'PARTNER_CLOSED');
  assert.equal(partnerRefusal('boulangerie', { isOpen: true }, T0).code, 'PARTNER_UNAVAILABLE');
  assert.equal(partnerRefusal('boulangerie', { isActive: true, isOpen: true, openTime: '06:00', closeTime: '20h00' }, T0), null);
  assert.equal(partnerRefusal('boulangerie', { isActive: true, isOpen: true, openTime: '13:00', closeTime: '20:00' }, T0).code, 'PARTNER_CLOSED');
});

// ── Interrupteur ──────────────────────────────────────────────────────────

test('interrupteur : désactivées par défaut, aucune lecture ni écriture', async () => {
  const w = world({ enabled: false });
  const r = await w.q(rReq);
  assert.equal(r.code, 'FEATURE_DISABLED');
  const r2 = await w.o({ quoteId: 'x', paymentMethod: 'wallet' });
  assert.equal(r2.code, 'FEATURE_DISABLED');
  assert.equal([...w.store.keys()].some((k) => k.startsWith('tariff_quotes/')), false);
  delete process.env.PARTNER_ORDERS_V2;
  const fn = buildQuotePartnerOrderCF({ ...w.deps, isEnabled: undefined }).run;
  assert.equal((await fn({ auth: auth('alice'), data: rReq })).code, 'FEATURE_DISABLED');
});

test('liste pilote (7C-1-S) : document absent, liste vide ou partenaire hors liste → aucun devis ni commande v2, aucune écriture', async () => {
  const cases = [
    [null, 'CREATION_CLOSED'], [{}, 'CREATION_CLOSED'], [{ pilotPartnerIds: ['r1'] }, 'CREATION_CLOSED'],
    [{ pilotPartnerIds: ['r1'], creationOpen: false }, 'CREATION_CLOSED'], [{ pilotPartnerIds: ['r1'], creationOpen: 'true' }, 'CREATION_CLOSED'],
    [{ creationOpen: true }, 'PARTNER_NOT_IN_PILOT'], [{ pilotPartnerIds: [], creationOpen: true }, 'PARTNER_NOT_IN_PILOT'],
    [{ pilotPartnerIds: ['autre'], creationOpen: true }, 'PARTNER_NOT_IN_PILOT'],
  ];
  for (const [cfgDoc, expected] of cases) {
    const w = world();
    if (cfgDoc === null) w.store.delete('config/partnerOrdersV2'); else w.store.set('config/partnerOrdersV2', cfgDoc);
    const r = await w.q(rReq);
    assert.equal(r.code, expected, JSON.stringify(cfgDoc));
    assert.equal([...w.store.keys()].some((k) => k.startsWith('tariff_quotes/')), false);
    assert.equal(wallet(w), 20000);
  }
});

test('liste pilote : retrait entre le devis et la création → création refusée sans débit ; partenaire listé inchangé', async () => {
  const w = world();
  const quote = await w.q(rReq);
  assert.equal(quote.success, true);
  w.store.set('config/partnerOrdersV2', { pilotPartnerIds: ['b1'], creationOpen: true });
  const refused = await w.o(create(quote, rReq));
  assert.equal(refused.code, 'PARTNER_NOT_IN_PILOT');
  assert.equal(wallet(w), 20000);
  assert.equal(orders(w).length, 0);
  assert.equal(ledger(w).length, 0);
  const bq = await w.q(bReq);
  // Arrêt d'urgence entre le devis et la création : refusé sans débit, la liste pilote n'a pas été vidée.
  w.store.set('config/partnerOrdersV2', { pilotPartnerIds: ['b1'], creationOpen: false });
  assert.equal((await w.o(create(bq, bReq))).code, 'CREATION_CLOSED');
  assert.equal(wallet(w), 20000);
  assert.equal(orders(w).length, 0);
  w.store.set('config/partnerOrdersV2', { pilotPartnerIds: ['b1'], creationOpen: true });
  assert.equal((await w.o(create(bq, bReq))).success, true, 'boulangerie listée et création ouverte : création v2 possible');
});

test('authentification : anonyme ou absente refusée', async () => {
  const w = world();
  await assert.rejects(() => w.qAs(null, rReq), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => w.qAs(auth('alice', 'anonymous'), rReq), (e) => e.code === 'unauthenticated');
});

// ── Devis ─────────────────────────────────────────────────────────────────

test('devis restaurant : prix relus côté serveur, frais officiels, total = produits + livraison', async () => {
  const w = world();
  const r = await w.q({ ...rReq, price: 1, productAmount: 1, deliveryFee: 0 });
  assert.equal(r.success, true);
  assert.equal(r.data.productAmount, 3500);
  assert.equal(r.data.deliveryFee > 0, true);
  assert.equal(r.data.total, 3500 + r.data.deliveryFee);
  assert.deepEqual(r.data.lines.map((l) => [l.itemId, l.unitPrice, l.subtotal]), [['m1', 1500, 3000], ['m2', 500, 500]]);
  const doc = w.store.get(`tariff_quotes/${r.data.quoteId}`);
  assert.deepEqual([doc.kind, doc.uid, doc.status, doc.amount], ['partner', 'alice', 'open', r.data.total]);
  assert.equal(doc.expiresAtMs - doc.createdAtMs, 600000);
  assert.deepEqual(w.limits[0], ['alice', 'quote_partner_order', 30, 60]);
});

test('devis boulangerie : article indisponible, supprimé, partenaire fermé ou introuvable refusés', async () => {
  const w = world();
  assert.equal((await w.q(bReq)).success, true);
  assert.equal((await w.q({ ...bReq, items: [{ itemId: 'p3', qty: 1 }] })).code, 'ITEM_UNAVAILABLE');
  assert.equal((await w.q({ ...bReq, items: [{ itemId: 'zzz', qty: 1 }] })).code, 'ITEM_UNAVAILABLE');
  assert.equal((await w.q({ ...rReq, items: [{ itemId: 'm3', qty: 1 }] })).code, 'ITEM_UNAVAILABLE');
  assert.equal((await w.q({ ...bReq, sellerId: 'nope' })).code, 'PARTNER_NOT_FOUND');
  w.store.set('boulangeries/b1', { ...w.store.get('boulangeries/b1'), isOpen: false });
  assert.equal((await w.q(bReq)).code, 'PARTNER_CLOSED');
});

test('devis : un article d\'un autre partenaire n\'est pas lu (menu du partenaire désigné seulement)', async () => {
  const w = world({ seed: { 'restaurants/r2': { name: 'Autre', lat: PLACE.lat, lng: PLACE.lng }, 'restaurants/r2/menu/x1': { name: 'X', price: 100 } } });
  assert.equal((await w.q({ ...rReq, items: [{ itemId: 'x1', qty: 1 }] })).code, 'ITEM_UNAVAILABLE');
});

test('devis : prix invalide, coordonnées invalides, service inconnu, mode non standard', async () => {
  const w = world({ seed: { 'restaurants/r1/menu/bad': { name: 'Bad', price: 12.5 }, 'restaurants/r1/menu/neg': { name: 'Neg', price: -5 } } });
  assert.equal((await w.q({ ...rReq, items: [{ itemId: 'bad', qty: 1 }] })).code, 'INVALID_PRICE');
  assert.equal((await w.q({ ...rReq, items: [{ itemId: 'neg', qty: 1 }] })).code, 'INVALID_PRICE');
  assert.equal((await w.q({ ...rReq, destination: { lat: 0, lng: 0 } })).code, 'INVALID_COORDINATES');
  assert.equal((await w.q({ ...rReq, sellerType: 'pharmacie' })).code, 'SERVICE_NOT_SUPPORTED');
  assert.equal((await w.q({ ...rReq, mode: 'express' })).code, 'INVALID_MODE');
});

// ── Création ──────────────────────────────────────────────────────────────

test('création wallet restaurant : débit du total exact, commande v2, budget = frais, journal déterministe, aucun crédit partenaire', async () => {
  const w = world();
  const quote = await w.q(rReq);
  const r = await w.o(create(quote, rReq));
  assert.equal(r.success, true);
  const { productAmount, deliveryFee, total } = quote.data;
  assert.equal(r.data.charged, total);
  assert.equal(wallet(w), 20000 - total);
  assert.deepEqual(ledger(w), [`clients/alice/wallet_transactions/order_${r.data.orderId}`]);
  const led = w.store.get(ledger(w)[0]);
  assert.deepEqual([led.type, led.amount, led.orderId, led.provider], ['payment', total, r.data.orderId, 'wallet']);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual(readPartnerAmounts(order), { productAmount, deliveryFee, totalAmount: total });
  assert.deepEqual([order.amountsVersion, order.budget, order.shoppingBudget, order.isPaid, order.status, order.paymentMethod],
    [2, deliveryFee, 0, true, 'pending', 'wallet']);
  assert.deepEqual([order.type, order.sellerType, order.sellerId, order.clientId], ['restaurant', 'restaurant', 'r1', 'alice']);
  assert.deepEqual([order.latitude, order.longitude, order.destLat, order.destLng], [PLACE.lat, PLACE.lng, DEST.lat, DEST.lng]);
  assert.deepEqual([order.tariffQuoteId, order.quotedAmount, order.source], [quote.data.quoteId, total, 'partner_quote']);
  assert.equal(order.pickupCityId, 'abengourou');
  // Aucun crédit partenaire/livreur à la création.
  assert.equal(w.store.get('restaurants/r1').wallet, undefined);
  assert.equal([...w.store.keys()].some((k) => k.startsWith('restaurants/r1/wallet_transactions')), false);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'used');
  assert.equal(w.audits.at(-1).action, 'create_partner_order');
});

test('création wallet boulangerie : champs de compatibilité (items superset, itemsAmount, sellerStatus null)', async () => {
  const w = world();
  const quote = await w.q(bReq);
  const r = await w.o(create(quote, bReq, { requestedTime: '08:30' }));
  assert.equal(r.success, true);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([order.itemsAmount, order.productAmount, order.sellerStatus, order.requestedTime, order.description],
    [1200, 1200, null, '08:30', 'Quartier Test, Abengourou']);
  assert.deepEqual(order.items.map((i) => [i.id, i.name, i.price, i.qty, i.subtotal, i.budgetFcfa]),
    [['p1', 'Baguette', 150, 4, 600, 600], ['p2', 'Croissant', 300, 2, 600, 600]]);
  assert.equal(order.totalAmount, 1200 + quote.data.deliveryFee);
});

test('création cash : aucun débit, aucun journal, commande non payée', async () => {
  const w = world();
  const quote = await w.q(rReq);
  const r = await w.o(create(quote, rReq, { paymentMethod: 'cash' }));
  assert.equal(r.success, true);
  assert.equal(r.data.charged, 0);
  assert.equal(wallet(w), 20000);
  assert.equal(ledger(w).length, 0);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([order.isPaid, order.paymentMethod, order.amountsVersion], [false, 'cash', 2]);
});

test('création : solde insuffisant, mobile money refusé, montant non confirmé, adresse requise', async () => {
  const w = world({ wallet: 100 });
  const quote = await w.q(rReq);
  const r = await w.o(create(quote, rReq));
  assert.equal(r.code, 'SOLDE_INSUFFISANT');
  assert.equal(wallet(w), 100); assert.equal(orders(w).length, 0);
  assert.equal((await w.o(create(quote, rReq, { paymentMethod: 'mobile_money' }))).code, 'PAYMENT_METHOD_UNSUPPORTED');
  const w2 = world();
  const q2 = await w2.q(rReq);
  assert.equal((await w2.o(create(q2, rReq, { confirmedAmount: q2.data.total - 1 }))).code, 'AMOUNT_NOT_CONFIRMED');
  assert.equal((await w2.o(create(q2, rReq, { confirmedAmount: undefined }))).code, 'AMOUNT_NOT_CONFIRMED');
  assert.equal((await w2.o(create(q2, rReq, { confirmedAmount: q2.data.total + 1 }))).code, 'AMOUNT_NOT_CONFIRMED');
  assert.equal((await w2.o(create(q2, rReq, { deliveryAddress: '' }))).code, 'INVALID_FIELD');
  assert.equal(wallet(w2), 20000); assert.equal(orders(w2).length, 0);
});

test('idempotence : rejeu du même devis = même commande, un seul débit, un seul journal', async () => {
  const w = world();
  const quote = await w.q(rReq);
  const a = await w.o(create(quote, rReq));
  const b = await w.o(create(quote, rReq));
  assert.equal(b.success, true); assert.equal(b.data.replayed, true);
  assert.equal(b.data.orderId, a.data.orderId);
  assert.equal(wallet(w), 20000 - quote.data.total);
  assert.equal(orders(w).length, 1); assert.equal(ledger(w).length, 1);
});

test('devis : lié au client (autre client = introuvable), expire, ne sert pas à un autre panier ni une autre destination', async () => {
  const w = world();
  const quote = await w.q(rReq);
  assert.equal((await w.o(create(quote, rReq), 'bob')).code, 'QUOTE_NOT_FOUND');
  assert.equal((await w.o(create(quote, { ...rReq, items: [{ itemId: 'm1', qty: 3 }] }))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(create(quote, { ...rReq, destination: { lat: 6.76, lng: -3.49 } }))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(create(quote, { ...rReq, sellerId: 'r2' }))).code, 'QUOTE_MISMATCH');
  w.setClock(T0 + 601000);
  assert.equal((await w.o(create(quote, rReq))).code, 'QUOTE_EXPIRED');
  assert.equal(wallet(w), 20000); assert.equal(orders(w).length, 0);
});

test('devis altéré (lignes modifiées sans empreinte) : refusé', async () => {
  const w = world();
  const quote = await w.q(rReq);
  const key = `tariff_quotes/${quote.data.quoteId}`;
  const doc = w.store.get(key);
  w.store.set(key, { ...doc, lines: doc.lines.map((l) => ({ ...l, unitPrice: 1, subtotal: l.qty })) });
  assert.equal((await w.o(create(quote, rReq))).code, 'QUOTE_CORRUPTED');
  assert.equal(wallet(w), 20000);
});

test('prix du menu en hausse : PRICE_CHANGED sans débit ; en baisse : nouveau montant à reconfirmer, puis débit exact', async () => {
  const w = world();
  const quote = await w.q(rReq);
  w.store.set('restaurants/r1/menu/m1', { name: 'Attiéké poisson', price: 1800, available: true });
  const up = await w.o(create(quote, rReq));
  assert.equal(up.code, 'PRICE_CHANGED');
  assert.equal(wallet(w), 20000); assert.equal(orders(w).length, 0);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'open');
  w.store.set('restaurants/r1/menu/m1', { name: 'Attiéké poisson', price: 1000, available: true });
  const stale = await w.o(create(quote, rReq));
  assert.equal(stale.code, 'PRICE_CHANGED');
  assert.equal(stale.data.decreased, true);
  assert.equal(stale.data.currentAmount, 2500 + quote.data.deliveryFee);
  assert.equal(wallet(w), 20000); assert.equal(orders(w).length, 0);
  const down = await w.o(create(quote, rReq, { confirmedAmount: stale.data.currentAmount }));
  assert.equal(down.success, true);
  assert.equal(down.data.productAmount, 2500);
  assert.equal(down.data.charged, 2500 + quote.data.deliveryFee);
  assert.equal(wallet(w), 20000 - down.data.charged);
});

test('article devenu indisponible / partenaire fermé entre devis et création : refus sans débit', async () => {
  const w = world();
  const quote = await w.q(bReq);
  w.store.set('boulangeries/b1/menu_items/p2', { name: 'Croissant', price: 300, isAvailable: false });
  assert.equal((await w.o(create(quote, bReq))).code, 'ITEM_UNAVAILABLE');
  w.store.set('boulangeries/b1/menu_items/p2', { name: 'Croissant', price: 300, isAvailable: true });
  w.store.set('boulangeries/b1', { ...w.store.get('boulangeries/b1'), isOpen: false });
  assert.equal((await w.o(create(quote, bReq))).code, 'PARTNER_CLOSED');
  assert.equal(wallet(w), 20000); assert.equal(orders(w).length, 0);
});

test('hors zone de service : OUTSIDE_SERVICE sans débit', async () => {
  const w = world();
  const quote = await w.q(rReq);
  w.deps.db.store.get('clients/alice');
  const fn = buildCreatePartnerOrderFromQuoteCF({
    ...w.deps, newOrderId: () => 'o-x',
    resolveGeography: async () => { throw Object.assign(new Error('Hors zone'), { code: 'outside-service' }); },
  }).run;
  const r = await fn({ auth: auth('alice'), data: create(quote, rReq) });
  assert.equal(r.code, 'OUTSIDE_SERVICE');
  assert.equal(wallet(w), 20000);
});

test('compte client supprimé : refusé', async () => {
  const w = world({ seed: { 'clients/alice': { wallet: 20000, deletionRequested: true } } });
  assert.equal((await w.q(rReq)).code, 'ACCOUNT_UNAVAILABLE');
});

// ── Isolation entre types de devis ────────────────────────────────────────

test('un devis partenaire ne sert ni à la livraison ni au catalogue', async () => {
  const w = world();
  const quote = await w.q(rReq);
  const base = { ...w.deps, newOrderId: () => 'o-y' };
  const catalog = buildCreateCatalogOrderFromQuoteCF(base).run;
  const rc = await catalog({ auth: auth('alice'), data: { quoteId: quote.data.quoteId, paymentMethod: 'wallet', service: 'colis', colisType: 'Colis standard' } });
  assert.equal(rc.success, false);
  const delivery = buildCreateOrderFromQuoteCF({ ...base, resolveGeography: async () => GEO }).run;
  const rd = await delivery({ auth: auth('alice'), data: { quoteId: quote.data.quoteId, serviceType: 'livraison', mode: 'standard', pickup: PLACE, destination: DEST, paymentMethod: 'wallet', order: { description: 'x' } } });
  assert.equal(rd.success, false);
  assert.equal(wallet(w), 20000); assert.equal(orders(w).length, 0);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'open');
});

// ── Commission d'acceptation inchangée ────────────────────────────────────

test('commission : calculée sur les frais seuls (budget), jamais sur les produits', async () => {
  const { calculateCommission } = require('../dispatch');
  const w = world();
  const quote = await w.q(rReq);
  const r = await w.o(create(quote, rReq));
  const order = w.store.get(`orders/${r.data.orderId}`);
  const commission = await calculateCommission(w.db, order.budget);
  assert.equal(commission, order.budget < 1000 ? 100 : 200);
  assert.equal(order.budget, order.deliveryFee);
  assert.equal(itemsFingerprint(quote.data.lines.map((l) => ({ ...l }))).length, 64);
});
