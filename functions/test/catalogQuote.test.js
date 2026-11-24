'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { buildQuoteCatalogCF, buildCreateCatalogOrderFromQuoteCF } = require('../catalogQuote');
const {
  COLIS, EAU, LIMITS, MIN_ORDER_BUDGET, BLANCHISSERIE_DEFAULTS, resolveBlanchisserieConfig, priceCatalogRequest,
} = require('../catalogTariff');

const admin = { firestore: { FieldValue: { serverTimestamp: () => 'TS' } } };
const auth = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });
const T0 = Date.UTC(2026, 10, 3, 12, 0, 0);

function world({ seed = {}, wallet = 10000, resolveGeography } = {}) {
  const db = fakeDb({
    'clients/alice': { wallet, name: 'Alice Test', phone: '+2250000000001' },
    'clients/bob': { wallet: 5000 },
    ...seed,
  });
  const audits = []; const limits = [];
  let clock = T0; let seq = 0;
  const deps = {
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async (uid, action, max, win) => { limits.push([uid, action, max, win]); },
    logAudit: async (a) => { audits.push(a); }, now: () => clock,
    resolveGeography: resolveGeography || (async () => ({
      pickupCityId: 'abengourou', deliveryCityId: 'abengourou',
      pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved',
    })),
  };
  const quoteFn = buildQuoteCatalogCF({ ...deps, randomId: () => `quote-${++seq}` }).run;
  const orderFn = buildCreateCatalogOrderFromQuoteCF({ ...deps, newOrderId: () => `order-${++seq}` }).run;
  const q = (data, uid = 'alice', a = auth(uid)) => quoteFn({ auth: a, data });
  const o = (data, uid = 'alice', a = auth(uid)) => orderFn({ auth: a, data });
  return { db, audits, limits, q, o, setClock: (ms) => { clock = ms; }, store: db.store };
}
const wallet = (w, uid = 'alice') => w.store.get(`clients/${uid}`).wallet;
const ledger = (w, uid = 'alice') => [...w.store.keys()].filter((k) => k.startsWith(`clients/${uid}/wallet_transactions/`));
const orders = (w) => [...w.store.keys()].filter((k) => k.startsWith('orders/'));

const colisReq = { service: 'colis', colisType: 'Colis standard', fragile: false };
const colisTexts = { recipientName: 'Kouassi', recipientPhone: '0700000000', recipientAddress: 'Quartier Dioulabougou', senderName: 'Alice', senderPhone: '0500000000', contentDescription: 'Livres' };
const blanchReq = { service: 'blanchisserie', serviceType: 'Lavage + Repassage', quantity: 3 };
const eauReq = { service: 'eau_boissons', items: [{ id: 'eau_1500', qty: 2 }, { id: 'coca_33', qty: 3 }] };
// Point par défaut valide (Abengourou) : les tests qui ne portent pas spécifiquement sur la géolocalisation
// n'ont pas besoin de le préciser.
const orderData = (quote, req, extra = {}) => ({
  quoteId: quote.data.quoteId, paymentMethod: 'wallet', lat: 6.7273, lng: -3.4961, coordinateSource: 'gps',
  ...req, ...extra,
});

// ── Catalogue : tarifs actuellement appliqués, inchangés ───────────────────

test('catalogue : prix identiques à ceux des écrans actuels (aucun tarif modifié)', () => {
  assert.deepEqual({ ...COLIS.types }, { 'Colis standard': 500, 'Cadeau emballé': 700, 'Document / Enveloppe': 300, 'Gros colis': 1000 });
  assert.equal(COLIS.fragileSurcharge, 200);
  assert.equal(BLANCHISSERIE_DEFAULTS.pricePerKg, 1000);
  assert.equal(EAU.deliveryFee, 500);
  assert.deepEqual(Object.fromEntries(Object.entries(EAU.products).map(([k, v]) => [k, v.price])),
    { eau_500: 200, eau_1500: 400, casier_eau: 3500, coca_33: 500, fanta_33: 500, sprite_33: 500, jus_tropics: 600, lait_500: 700, energie: 800 });
});

test('catalogue : colis = prix du type + fragile ; blanchisserie = kilos × prix/kg ; eau = articles + livraison', () => {
  const c = priceCatalogRequest('colis', { colisType: 'Cadeau emballé', fragile: true });
  assert.deepEqual([c.budget, c.shoppingBudget, c.total], [900, 0, 900]);
  const b = priceCatalogRequest('blanchisserie', { serviceType: 'Pressing', quantity: 7 });
  assert.deepEqual([b.budget, b.shoppingBudget, b.total], [7000, 0, 7000]);
  const e = priceCatalogRequest('eau_boissons', { items: [{ id: 'casier_eau', qty: 2 }, { id: 'eau_500', qty: 5 }] });
  assert.deepEqual([e.budget, e.shoppingBudget, e.total], [500, 8000, 8500]);
});

test('catalogue : « Document / Enveloppe » reste à 300 FCFA et est commandable (exception unique) ; le minimum des autres reste 500', () => {
  const d = priceCatalogRequest('colis', { colisType: 'Document / Enveloppe' });
  assert.deepEqual([d.budget, d.shoppingBudget, d.total], [300, 0, 300]);
  assert.equal(priceCatalogRequest('colis', { colisType: 'Document / Enveloppe', fragile: true }).total, 500);
  assert.equal(MIN_ORDER_BUDGET, 500);
  // Le minimum global de 500 FCFA s'applique toujours aux autres services (prix au kilo administré bas).
  const cheap = resolveBlanchisserieConfig({ pricePerKg: 100 });
  assert.throws(() => priceCatalogRequest('blanchisserie', { serviceType: 'Pressing', quantity: 1 }, { blanchisserieConfig: cheap }),
    (e) => e.code === 'BELOW_MINIMUM_ORDER' && e.data.minimum === 500);
  assert.equal(priceCatalogRequest('blanchisserie', { serviceType: 'Pressing', quantity: 5 }, { blanchisserieConfig: cheap }).total, 500);
});

test('catalogue : plafonds provisoires (30 kg, 20 unités par produit, 5 casiers, panier 50 000, poids estimé)', () => {
  assert.equal(priceCatalogRequest('blanchisserie', { serviceType: 'Pressing', quantity: LIMITS.blanchisserieMaxKg }).total, 30000);
  assert.throws(() => priceCatalogRequest('blanchisserie', { serviceType: 'Pressing', quantity: 31 }), (e) => e.code === 'QUANTITY_TOO_HIGH');
  assert.equal(priceCatalogRequest('eau_boissons', { items: [{ id: 'eau_500', qty: 20 }] }).shoppingBudget, 4000);
  assert.throws(() => priceCatalogRequest('eau_boissons', { items: [{ id: 'eau_500', qty: 21 }] }), (e) => e.code === 'QUANTITY_TOO_HIGH');
  // Casiers : 5 au plus par commande (plafond par produit), puis garde de poids pour un trajet à moto.
  assert.throws(() => priceCatalogRequest('eau_boissons', { items: [{ id: 'casier_eau', qty: 6 }] }), (e) => e.code === 'QUANTITY_TOO_HIGH' && e.data.maxQty === 5);
  assert.equal(priceCatalogRequest('eau_boissons', { items: [{ id: 'casier_eau', qty: 2 }] }).shoppingBudget, 7000);
  for (const qty of [3, 5]) {
    assert.throws(() => priceCatalogRequest('eau_boissons', { items: [{ id: 'casier_eau', qty }] }), (e) => e.code === 'BASKET_TOO_HEAVY', `${qty} casiers`);
  }
  // Panier > 50 000 FCFA (articles hors casiers, à la quantité maximale).
  const every = Object.keys(EAU.products).filter((id) => id !== 'casier_eau').map((id) => ({ id, qty: 20 }));
  assert.throws(() => priceCatalogRequest('eau_boissons', { items: every }), (e) => e.code === 'BASKET_TOO_HIGH');
  assert.equal(priceCatalogRequest('eau_boissons', { items: [{ id: 'energie', qty: 20 }, { id: 'lait_500', qty: 20 }, { id: 'jus_tropics', qty: 20 }] }).shoppingBudget, 42000);
});

test('catalogue : entrées invalides refusées (types, quantités, doublons, produits inconnus)', () => {
  const bad = (svc, input, code) => assert.throws(() => priceCatalogRequest(svc, input), (e) => e.code === code, JSON.stringify(input));
  bad('colis', { colisType: 'Inconnu' }, 'INVALID_ITEM');
  bad('colis', { colisType: '__proto__' }, 'INVALID_ITEM');
  bad('colis', { colisType: 'Colis standard', fragile: 'oui' }, 'INVALID_PARAMS');
  for (const quantity of [0, -3, 2.5, '3', null, NaN, Infinity]) bad('blanchisserie', { serviceType: 'Pressing', quantity }, 'INVALID_QUANTITY');
  bad('blanchisserie', { serviceType: 'Teinture', quantity: 1 }, 'INVALID_ITEM');
  bad('eau_boissons', { items: [] }, 'INVALID_ITEMS');
  bad('eau_boissons', { items: 'x' }, 'INVALID_ITEMS');
  bad('eau_boissons', { items: [{ id: 'bière', qty: 1 }] }, 'INVALID_ITEM');
  bad('eau_boissons', { items: [{ id: 'constructor', qty: 1 }] }, 'INVALID_ITEM');
  bad('eau_boissons', { items: [{ id: 'eau_500', qty: 1 }, { id: 'eau_500', qty: 2 }] }, 'DUPLICATE_ITEM');
  bad('eau_boissons', { items: [{ id: 'eau_500', qty: 0 }] }, 'INVALID_QUANTITY');
  bad('eau_boissons', { items: [{ id: 'eau_500', qty: -1 }] }, 'INVALID_QUANTITY');
  bad('livraison', {}, 'SERVICE_NOT_SUPPORTED');
});

test('prix au kilo administrable : valeur valide appliquée, invalide ignorée (prix par défaut)', () => {
  assert.equal(resolveBlanchisserieConfig({ pricePerKg: 1500 }).pricePerKg, 1500);
  assert.equal(resolveBlanchisserieConfig({ pricePerKg: 1500 }).source, 'app_config');
  for (const bad of [0, -5, 99, 10001, 1200.5, '1500', null, NaN]) {
    const cfg = resolveBlanchisserieConfig({ pricePerKg: bad });
    assert.equal(cfg.pricePerKg, 1000, String(bad));
    assert.deepEqual(cfg.issues, ['pricePerKg_invalid']);
  }
  assert.deepEqual(resolveBlanchisserieConfig(null).services, [...BLANCHISSERIE_DEFAULTS.services]);
  assert.deepEqual(resolveBlanchisserieConfig({ services: ['A', 'B'] }).services, ['A', 'B']);
  assert.deepEqual(resolveBlanchisserieConfig({ services: [] }).issues, ['services_invalid']);
  assert.deepEqual(resolveBlanchisserieConfig({ services: [1] }).issues, ['services_invalid']);
});

// ── Devis ──────────────────────────────────────────────────────────────────

test('devis : montants posés par le serveur, document lié au client, au service et aux choix, expiration limitée', async () => {
  const w = world();
  // Le client tente d'imposer montants et prix : ignorés.
  const r = await w.q({ ...colisReq, budget: 1, total: 1, amount: 1, price: 1, shoppingBudget: -5000 });
  assert.equal(r.success, true);
  assert.deepEqual([r.data.budget, r.data.shoppingBudget, r.data.total], [500, 0, 500]);
  const stored = w.store.get(`tariff_quotes/${r.data.quoteId}`);
  assert.deepEqual([stored.kind, stored.uid, stored.status, stored.serviceType, stored.amount], ['catalog', 'alice', 'open', 'colis', 500]);
  assert.deepEqual(stored.params, { colisType: 'Colis standard', fragile: false });
  assert.equal(stored.expiresAtMs, T0 + 10 * 60 * 1000);
  assert.deepEqual(w.limits[0].slice(1), ['quote_catalog', 30, 60]);
});

test('devis : blanchisserie lit le prix au kilo administré (relu et validé par le serveur)', async () => {
  const w = world({ seed: { 'app_config/blanchisserie': { pricePerKg: 1500 } } });
  const r = await w.q(blanchReq);
  assert.deepEqual([r.data.total, r.data.pricePerKg], [4500, 1500]);
  const w2 = world({ seed: { 'app_config/blanchisserie': { pricePerKg: 1 } } });
  assert.equal((await w2.q(blanchReq)).data.total, 3000, 'valeur hors bornes ignorée : prix par défaut');
  assert.equal((await world().q(blanchReq)).data.total, 3000, 'document absent : prix par défaut');
});

test('devis : colis et eau ignorent app_config (les clients ne le lisent pas aujourd\'hui → prix inchangés)', async () => {
  const w = world({ seed: { 'app_config/colis': { types: [{ label: 'Colis standard', price: 1 }] }, 'app_config/eau_boissons': { deliveryFee: 1 } } });
  assert.equal((await w.q(colisReq)).data.total, 500);
  assert.equal((await w.q(eauReq)).data.total, 500 + 2 * 400 + 3 * 500);
});

test('devis : refus (non connecté, anonyme, service inconnu, compte absent ou en suppression, paramètres manipulés)', async () => {
  const w = world({ seed: { 'clients/gone': { wallet: 1, deletionRequested: true } } });
  await assert.rejects(() => w.q(colisReq, null, null), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => w.q(colisReq, 'alice', auth('alice', 'anonymous')), (e) => e.code === 'unauthenticated');
  assert.equal((await w.q({ service: 'livraison' })).code, 'SERVICE_NOT_SUPPORTED');
  assert.equal((await w.q(colisReq, 'fantome')).code, 'CLIENT_NOT_FOUND');
  assert.equal((await w.q(colisReq, 'gone')).code, 'ACCOUNT_UNAVAILABLE');
  assert.equal((await w.q({ ...colisReq, colisType: 'Gratuit' })).code, 'INVALID_ITEM');
  assert.equal((await w.q({ ...blanchReq, quantity: 500 })).code, 'QUANTITY_TOO_HIGH');
  assert.equal([...w.store.keys()].filter((k) => k.startsWith('tariff_quotes/')).length, 0);
});

// ── Commande : prix normal, débit, forme ───────────────────────────────────

test('commande colis wallet : débit exact, ligne de journal déterministe, forme identique à l\'écran actuel', async () => {
  const w = world();
  const quote = await w.q({ ...colisReq, colisType: 'Cadeau emballé', fragile: true });
  const r = await w.o(orderData(quote, { ...colisReq, colisType: 'Cadeau emballé', fragile: true }, colisTexts));
  assert.equal(r.success, true);
  assert.deepEqual(r.data, { orderId: 'order-2', charged: 900 });
  assert.equal(wallet(w), 9100);
  assert.deepEqual(ledger(w), ['clients/alice/wallet_transactions/order_order-2']);
  const l = w.store.get('clients/alice/wallet_transactions/order_order-2');
  assert.deepEqual([l.type, l.amount, l.orderId], ['payment', 900, 'order-2']);
  const order = w.store.get('orders/order-2');
  // Mêmes champs que colis_page.dart (budget, shoppingBudget, type, colisType, fragile, textes, paiement…).
  for (const k of ['id', 'description', 'budget', 'shoppingBudget', 'status', 'type', 'colisType', 'fragile', 'senderName', 'senderPhone',
    'recipientName', 'recipientPhone', 'recipientAddress', 'contentDescription', 'latitude', 'longitude', 'clientId', 'paymentMethod', 'isPaid', 'createdAt']) {
    assert.ok(k in order, `champ manquant : ${k}`);
  }
  assert.deepEqual([order.budget, order.shoppingBudget, order.status, order.type, order.isPaid, order.clientId, order.paymentMethod],
    [900, 0, 'pending', 'colis', true, 'alice', 'wallet']);
  assert.match(order.description, /^Colis : Cadeau emballé \(Fragile\)\nExpéditeur : Alice — 0500000000\nDestinataire : Kouassi — 0700000000\nAdresse : Quartier Dioulabougou\nContenu : Livres$/);
  assert.equal(order.tariffQuoteId, quote.data.quoteId);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'used');
  assert.equal(w.audits.at(-1).amount, 900);
});

test('commande blanchisserie : budget = kilos × prix, aucun budget d\'achat ; eau : budget = livraison, shoppingBudget = articles', async () => {
  const w = world();
  const qb = await w.q(blanchReq);
  const rb = await w.o(orderData(qb, blanchReq, { address: 'Rue 12', notes: 'Délicat' }));
  const ob = w.store.get(`orders/${rb.data.orderId}`);
  assert.deepEqual([ob.budget, ob.shoppingBudget, ob.type, ob.serviceType, ob.quantity, ob.address, ob.notes], [3000, 0, 'blanchisserie', 'Lavage + Repassage', 3, 'Rue 12', 'Délicat']);
  const qe = await w.q(eauReq);
  const re = await w.o(orderData(qe, eauReq, { address: 'Rue 13' }));
  const oe = w.store.get(`orders/${re.data.orderId}`);
  assert.deepEqual([oe.budget, oe.shoppingBudget, oe.type], [500, 2300, 'eau_boissons']);
  assert.deepEqual(oe.items, [
    { id: 'eau_1500', name: 'Eau 1.5L', price: 400, qty: 2, subtotal: 800 },
    { id: 'coca_33', name: 'Coca-Cola 33cl', price: 500, qty: 3, subtotal: 1500 },
  ]);
  assert.equal(wallet(w), 10000 - 3000 - 2800);
});

test('commande espèces : aucun débit, isPaid false, devis consommé', async () => {
  const w = world();
  const quote = await w.q(eauReq);
  const r = await w.o(orderData(quote, eauReq, { address: 'Rue 1', paymentMethod: 'cash' }));
  assert.equal(r.data.charged, 0);
  assert.equal(wallet(w), 10000);
  assert.equal(ledger(w).length, 0);
  assert.deepEqual([w.store.get(`orders/${r.data.orderId}`).isPaid, w.store.get(`orders/${r.data.orderId}`).paymentMethod], [false, 'cash']);
});

// ── Manipulations ──────────────────────────────────────────────────────────

test('prix manipulé : montants du client ignorés, confirmedAmount trop bas refusé sans débit', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const low = await w.o(orderData(quote, colisReq, { ...colisTexts, confirmedAmount: 1 }));
  assert.equal(low.code, 'AMOUNT_NOT_CONFIRMED');
  assert.equal(wallet(w), 10000);
  const r = await w.o(orderData(quote, colisReq, { ...colisTexts, budget: 1, shoppingBudget: -400, total: 1, amount: 1, isPaid: false, confirmedAmount: 500 }));
  assert.equal(r.success, true);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([order.budget, order.shoppingBudget, order.isPaid], [500, 0, true]);
  assert.equal(wallet(w), 9500);
});

test('quantité / choix manipulés : la commande doit correspondre exactement au devis', async () => {
  const w = world();
  const qb = await w.q(blanchReq);
  assert.equal((await w.o(orderData(qb, { ...blanchReq, quantity: 1 }, { address: 'x' }))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(orderData(qb, { ...blanchReq, serviceType: 'Pressing' }, { address: 'x' }))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(orderData(qb, { ...blanchReq, quantity: 30 }, { address: 'x' }))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(orderData(qb, { ...blanchReq, quantity: 31 }, { address: 'x' }))).code, 'QUANTITY_TOO_HIGH');
  const qe = await w.q(eauReq);
  assert.equal((await w.o(orderData(qe, { ...eauReq, items: [{ id: 'eau_1500', qty: 1 }, { id: 'coca_33', qty: 3 }] }, { address: 'x' }))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(orderData(qe, { ...eauReq, items: [{ id: 'eau_1500', qty: 2 }, { id: 'coca_33', qty: 3 }, { id: 'energie', qty: 1 }] }, { address: 'x' }))).code, 'QUOTE_MISMATCH');
  const qc = await w.q(colisReq);
  assert.equal((await w.o(orderData(qc, { ...colisReq, colisType: 'Gros colis' }, colisTexts))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o(orderData(qc, { ...colisReq, fragile: true }, colisTexts))).code, 'QUOTE_MISMATCH');
  assert.equal((await w.o({ ...orderData(qc, colisReq, colisTexts), service: 'blanchisserie', serviceType: 'Pressing', quantity: 1, address: 'x' })).code, 'QUOTE_MISMATCH');
  assert.equal(wallet(w), 10000);
  assert.equal(orders(w).length, 0);
});

test('devis expiré : refusé sans débit ni commande', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  w.setClock(T0 + 10 * 60 * 1000 + 1);
  const r = await w.o(orderData(quote, colisReq, colisTexts));
  assert.equal(r.code, 'QUOTE_EXPIRED');
  assert.equal(wallet(w), 10000);
  assert.equal(orders(w).length, 0);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'open');
});

test('droits : devis d\'un autre client, de la livraison ou inexistant → introuvable, aucun effet', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  assert.equal((await w.o(orderData(quote, colisReq, colisTexts), 'bob')).code, 'QUOTE_NOT_FOUND');
  assert.equal((await w.o({ ...orderData(quote, colisReq, colisTexts), quoteId: 'absent' })).code, 'QUOTE_NOT_FOUND');
  w.store.set('tariff_quotes/delivery-1', { uid: 'alice', status: 'open', serviceType: 'livraison', amount: 500, expiresAtMs: T0 + 1e6 });
  assert.equal((await w.o({ ...orderData(quote, colisReq, colisTexts), quoteId: 'delivery-1' })).code, 'QUOTE_NOT_FOUND');
  await assert.rejects(() => w.o(orderData(quote, colisReq, colisTexts), null, null), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => w.o(orderData(quote, colisReq, colisTexts), 'alice', auth('alice', 'anonymous')), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => w.o({ ...orderData(quote, colisReq, colisTexts), quoteId: 'a/b' }), (e) => e.code === 'invalid-argument');
  assert.equal((await w.o({ ...orderData(quote, colisReq, colisTexts), paymentMethod: 'orange_money' })).code, 'PAYMENT_METHOD_UNSUPPORTED');
  assert.equal(wallet(w), 10000);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'open');
});

test('compte en suppression entre le devis et la commande : refus sans débit', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  w.store.set('clients/alice', { ...w.store.get('clients/alice'), deletionRequested: true });
  const r = await w.o(orderData(quote, colisReq, colisTexts));
  assert.equal(r.code, 'ACCOUNT_UNAVAILABLE');
  assert.equal(wallet(w), 10000);
});

// ── Double commande / double débit / solde ─────────────────────────────────

test('double commande : le même devis rejoué retrouve la même commande, un seul débit', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const first = await w.o(orderData(quote, colisReq, colisTexts));
  const again = await w.o(orderData(quote, colisReq, colisTexts));
  assert.equal(again.success, true);
  assert.deepEqual([again.data.orderId, again.data.replayed, again.data.charged], [first.data.orderId, true, 500]);
  assert.equal(wallet(w), 9500);
  assert.equal(orders(w).length, 1);
  assert.equal(ledger(w).length, 1);
});

test('solde insuffisant : aucun débit, aucune commande, devis réutilisable après recharge', async () => {
  const w = world({ wallet: 400 });
  const quote = await w.q(colisReq);
  const r = await w.o(orderData(quote, colisReq, colisTexts));
  assert.equal(r.code, 'SOLDE_INSUFFISANT');
  assert.match(r.message, /^SOLDE_INSUFFISANT:400:500$/);
  assert.equal(wallet(w), 400);
  assert.equal(orders(w).length, 0);
  assert.equal(w.store.get(`tariff_quotes/${quote.data.quoteId}`).status, 'open');
  w.store.set('clients/alice', { ...w.store.get('clients/alice'), wallet: 800 });
  assert.equal((await w.o(orderData(quote, colisReq, colisTexts))).success, true);
  assert.equal(wallet(w), 300);
});

test('solde négatif ou invalide : jamais de débit supplémentaire', async () => {
  for (const bad of [-100, NaN, 'beaucoup', null]) {
    const w = world({ wallet: bad });
    const quote = await w.q(colisReq);
    assert.equal((await w.o(orderData(quote, colisReq, colisTexts))).code, 'SOLDE_INSUFFISANT', String(bad));
    assert.equal(orders(w).length, 0);
  }
});

test('prix modifié entre devis et commande : hausse → PRICE_CHANGED sans débit ; baisse → le client paie le moindre', async () => {
  const w = world({ seed: { 'app_config/blanchisserie': { pricePerKg: 1000 } } });
  const quote = await w.q(blanchReq);
  w.store.set('app_config/blanchisserie', { pricePerKg: 2000 });
  const up = await w.o(orderData(quote, blanchReq, { address: 'x' }));
  assert.equal(up.code, 'PRICE_CHANGED');
  assert.deepEqual(up.data, { quotedAmount: 3000, currentAmount: 6000 });
  assert.equal(wallet(w), 10000);
  w.store.set('app_config/blanchisserie', { pricePerKg: 800 });
  const down = await w.o(orderData(quote, blanchReq, { address: 'x' }));
  assert.equal(down.data.charged, 2400);
  assert.equal(w.store.get(`orders/${down.data.orderId}`).budget, 2400);
  assert.equal(wallet(w), 7600);
});

test('champs texte : requis, bornés, jamais interprétés comme des montants', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  assert.equal((await w.o(orderData(quote, colisReq, { ...colisTexts, recipientName: '' }))).code, 'INVALID_FIELD');
  assert.equal((await w.o(orderData(quote, colisReq, { ...colisTexts, recipientAddress: 42 }))).code, 'INVALID_FIELD');
  assert.equal(wallet(w), 10000);
  const r = await w.o(orderData(quote, colisReq, { ...colisTexts, contentDescription: 'x'.repeat(5000) }));
  assert.equal(w.store.get(`orders/${r.data.orderId}`).contentDescription.length, 500);
});

test('compatibilité : le devis de livraison ne peut pas servir ici et inversement (types de devis séparés)', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  // Un devis catalogue ne comporte ni départ ni destination : le flux de livraison le rejetterait (kind = catalog).
  const stored = w.store.get(`tariff_quotes/${quote.data.quoteId}`);
  assert.equal(stored.pickup, undefined);
  assert.equal(stored.kind, 'catalog');
});

test('Document / Enveloppe 300 FCFA : devis, commande wallet (débit 300, journal), espèces sans débit, plafond bas inchangé', async () => {
  const doc = { service: 'colis', colisType: 'Document / Enveloppe', fragile: false };
  const w = world({ wallet: 1000 });
  const quote = await w.q(doc);
  assert.equal(quote.data.total, 300);
  const r = await w.o(orderData(quote, doc, colisTexts));
  assert.equal(r.success, true);
  assert.equal(wallet(w), 700);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([order.budget, order.shoppingBudget, order.isPaid, order.paymentMethod, order.status], [300, 0, true, 'wallet', 'pending']);
  assert.equal(w.store.get(`clients/alice/wallet_transactions/order_${r.data.orderId}`).amount, 300);
  const cash = await w.o(orderData(await w.q(doc), doc, { ...colisTexts, paymentMethod: 'cash' }));
  assert.equal(cash.success, true);
  assert.equal(wallet(w), 700);
  assert.equal(w.store.get(`orders/${cash.data.orderId}`).isPaid, false);
});

// ── Géolocalisation (correction release readiness — S6-Lot A Phase 4) ──────
// `createCatalogOrderFromQuoteCF` écrivait auparavant latitude/longitude à 0 (jamais exploitable par le dispatch,
// voir dispatchRetry.js::assertValidDispatchPoint) : une commande catalogue n'était jamais proposée à un livreur.
// Un point réel est désormais exigé et validé avant toute création de commande.

test('position manquante : commande refusée, aucun débit, aucune commande créée (jamais de repli 0,0)', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const r = await w.o(orderData(quote, colisReq, { ...colisTexts, lat: undefined, lng: undefined }));
  assert.equal(r.code, 'LOCATION_REQUIRED');
  assert.equal(wallet(w), 10000);
  assert.deepEqual(orders(w), []);
});

test('position (0,0) explicitement refusée, même si transmise par le client', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const r = await w.o(orderData(quote, colisReq, { ...colisTexts, lat: 0, lng: 0 }));
  assert.equal(r.code, 'LOCATION_REQUIRED');
  assert.equal(wallet(w), 10000);
  assert.deepEqual(orders(w), []);
});

test('position hors bornes (latitude/longitude invalides) refusée', async () => {
  const w = world();
  for (const bad of [{ lat: 95, lng: -3.5 }, { lat: 6.7, lng: 190 }, { lat: 'nord', lng: -3.5 }, { lat: NaN, lng: -3.5 }]) {
    const quote = await w.q(colisReq);
    const r = await w.o(orderData(quote, colisReq, { ...colisTexts, ...bad }));
    assert.equal(r.code, 'LOCATION_REQUIRED');
  }
  assert.equal(wallet(w), 10000);
  assert.deepEqual(orders(w), []);
});

test('position hors zone desservie : refus explicite OUTSIDE_SERVICE, aucun débit', async () => {
  const w = world({
    resolveGeography: async () => { throw Object.assign(new Error('hors villes'), { code: 'outside-service' }); },
  });
  const quote = await w.q(colisReq);
  const r = await w.o(orderData(quote, colisReq, colisTexts));
  assert.equal(r.code, 'OUTSIDE_SERVICE');
  assert.equal(wallet(w), 10000);
  assert.deepEqual(orders(w), []);
});

test('position valide : la commande porte des coordonnées réelles et la géographie résolue (compatibles avec dispatchOrder/retryPendingDispatch)', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const r = await w.o(orderData(quote, colisReq, { ...colisTexts, lat: 6.7301, lng: -3.4967, coordinateSource: 'google' }));
  assert.equal(r.success, true);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual(
    [order.latitude, order.longitude, order.deliveryLatitude, order.deliveryLongitude, order.destLat, order.destLng],
    [6.7301, -3.4967, 6.7301, -3.4967, 6.7301, -3.4967],
  );
  assert.deepEqual(
    [order.pickupCityId, order.deliveryCityId, order.pickupZoneId, order.deliveryZoneId, order.cityResolutionStatus],
    ['abengourou', 'abengourou', 'centre', 'centre', 'resolved'],
  );
  assert.deepEqual([order.pickupCoordinateSource, order.deliveryCoordinateSource], ['google', 'google']);
});

test('coordinateSource inconnu ou absent : replié sur "gps" (jamais une valeur arbitraire non reconnue)', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const r = await w.o(orderData(quote, colisReq, { ...colisTexts, coordinateSource: 'invente' }));
  assert.equal(r.success, true);
  const order = w.store.get(`orders/${r.data.orderId}`);
  assert.equal(order.pickupCoordinateSource, 'gps');
});

for (const [label, req, texts] of [
  ['colis', colisReq, colisTexts], ['blanchisserie', blanchReq, {}], ['eau_boissons', eauReq, {}],
]) {
  test(`position valide pour le service ${label} : commande créée avec des coordonnées exploitables`, async () => {
    const w = world();
    const quote = await w.q(req);
    const r = await w.o(orderData(quote, req, { ...texts, address: 'Quartier Dioulabougou' }));
    assert.equal(r.success, true);
    const order = w.store.get(`orders/${r.data.orderId}`);
    assert.equal(order.latitude, 6.7273);
    assert.equal(order.cityResolutionStatus, 'resolved');
  });
}

test('rejeu d\'un devis déjà utilisé : la commande retrouvée garde ses coordonnées d\'origine, pas de second appel à la géographie', async () => {
  const w = world();
  const quote = await w.q(colisReq);
  const first = await w.o(orderData(quote, colisReq, { ...colisTexts, lat: 6.71, lng: -3.44 }));
  // Rejeu avec un point DIFFÉRENT : la commande déjà créée est retrouvée telle quelle (pas de recalcul de géographie).
  const second = await w.o(orderData(quote, colisReq, { ...colisTexts, lat: 6.72, lng: -3.45 }));
  assert.equal(second.data.orderId, first.data.orderId);
  assert.equal(w.store.get(`orders/${first.data.orderId}`).latitude, 6.71);
});
