'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeDb } = require('./fakeFirestore');
const { createQuote, buildCreateOrderFromQuoteCF, buildQuoteDeliveryCF } = require('../deliveryQuote');

const CENTER = { lat: 6.7273, lng: -3.4961 };
const DEST = { lat: 6.7453, lng: -3.4961 }; // ~2 km, zone centrale
const at = (h, m = 0) => Date.UTC(2026, 5, 1, h, m);
const admin = { firestore: { FieldValue: { serverTimestamp: () => 'TS' } } };
class HttpsError extends Error { constructor(code, message) { super(message); this.code = code; } }
const onCall = (h) => h;

function world({ wallet = 5000, nowMs = at(12) } = {}) {
  const db = fakeDb({ 'clients/alice': { wallet, name: 'Alice Test', phone: '+2250000000001' }, 'clients/bob': { wallet: 5000 } });
  const audits = [];
  let clock = nowMs, seq = 0;
  const base = { db, admin, onCall, HttpsError, checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); }, now: () => clock, newOrderId: () => `order${seq++}`,
    resolveGeography: async () => ({ pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' }) };
  const create = buildCreateOrderFromQuoteCF(base);
  const quote = (uid, data, ms = clock) => createQuote({ db, admin, uid, data: { serviceType: 'livraison', pickup: CENTER, destination: DEST, ...data }, nowMs: ms });
  const setClock = (ms) => { clock = ms; };
  return { db, audits, create, quote, setClock };
}
const call = (fn, uid, data) => fn({ auth: uid ? { uid } : null, data });
const orderReq = (quoteId, extra = {}) => ({ quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'colis test' }, ...extra });

test('devis : lié au client, au service, aux points, au montant et à la version ; identifiant aléatoire', async () => {
  const w = world();
  const a = await w.quote('alice', {});
  assert.equal(a.success, true); assert.equal(a.data.amount, 500);
  const b = await w.quote('alice', {}, at(12, 1));
  const ids = [a.data.quoteId, b.data.quoteId];
  assert.notEqual(ids[0], ids[1]);
  const doc = w.db.store.get(`tariff_quotes/${a.data.quoteId}`);
  assert.deepEqual([doc.uid, doc.status, doc.serviceType, doc.mode, doc.amount, doc.tariffVersion], ['alice', 'open', 'livraison', 'standard', 500, 1]);
  assert.equal(doc.expiresAtMs - doc.createdAtMs, 600000);
  assert.deepEqual(doc.destination, { lat: 6.7453, lng: -3.4961 });
});

test('devis : refus des entrées invalides, sans écriture', async () => {
  const w = world();
  for (const data of [{ destination: { lat: 0, lng: 0 } }, { pickup: null }, { mode: 'turbo' }, { serviceType: 'nope' }, { destination: { lat: 'a', lng: 2 } }]) {
    const r = await w.quote('alice', data);
    assert.equal(r.success, false, JSON.stringify(data));
  }
  assert.equal([...w.db.store.keys()].filter((k) => k.startsWith('tariff_quotes/')).length, 0);
});

test('devis : le client ne peut pas imposer le montant ni la distance', async () => {
  const w = world();
  const r = await w.quote('alice', { amount: 1, price: 1, routeDistanceKm: 0.01, destination: { lat: 6.95, lng: -3.4961 } });
  assert.equal(r.success, true);
  assert.ok(r.data.amount >= 1500, `obtenu ${r.data.amount}`);
});

test('création : débite exactement le montant du devis, crée la commande côté serveur', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId, { budget: 1, amount: 1, isPaid: false, status: 'delivered', clientId: 'bob' }));
  assert.equal(r.success, true, JSON.stringify(r));
  assert.equal(w.db.store.get('clients/alice').wallet, 4500);
  const o = w.db.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([o.clientId, o.status, o.budget, o.isPaid, o.tariffQuoteId], ['alice', 'pending', 500, true, q.data.quoteId]);
  assert.equal(w.db.store.get(`clients/alice/wallet_transactions/order_${r.data.orderId}`).amount, 500);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'used');
  assert.equal(w.audits.at(-1).action, 'create_order_from_quote');
});

test('création : espèces → aucun débit ; budget d\'achat libre non transformé en prix', async () => {
  const w = world();
  const q = await w.quote('alice', { serviceType: 'courses' });
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId, { serviceType: 'courses', paymentMethod: 'cash', shoppingBudget: 7300 }));
  assert.equal(r.success, true);
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
  const o = w.db.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([o.budget, o.shoppingBudget, o.isPaid, o.type], [500, 7300, false, 'shopping']);
  const q2 = await w.quote('alice', { serviceType: 'courses' });
  const r2 = await call(w.create, 'alice', orderReq(q2.data.quoteId, { serviceType: 'courses', shoppingBudget: 1000 }));
  assert.equal(w.db.store.get('clients/alice').wallet, 5000 - 500 - 1000, 'wallet : livraison + budget d\'achat');
  assert.equal(r2.data.charged, 1500);
  const q3 = await w.quote('alice', {});
  await assert.rejects(call(w.create, 'alice', orderReq(q3.data.quoteId, { shoppingBudget: 99999999 })), { code: 'invalid-argument' });
});

test('devis expiré refusé, aucun débit', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  w.setClock(at(12, 10, 1) + 1000);
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId));
  assert.equal(r.code, 'QUOTE_EXPIRED');
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
});

test('devis appartenant à un autre client : refusé sans révéler son existence', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const r = await call(w.create, 'bob', orderReq(q.data.quoteId));
  assert.equal(r.code, 'QUOTE_NOT_FOUND');
  assert.equal(w.db.store.get('clients/bob').wallet, 5000);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open');
  assert.equal((await call(w.create, 'bob', orderReq('inexistant'))).code, 'QUOTE_NOT_FOUND');
});

test('réutilisation : un devis ne crée jamais une seconde commande ni un second débit ; rejeu = même commande', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const first = await call(w.create, 'alice', orderReq(q.data.quoteId));
  assert.equal(first.success, true);
  const again = await call(w.create, 'alice', orderReq(q.data.quoteId));
  assert.equal(again.success, true); assert.equal(again.data.replayed, true);
  assert.equal(again.data.orderId, first.data.orderId); assert.equal(again.data.charged, 500);
  assert.equal(w.db.store.get('clients/alice').wallet, 4500);
  assert.equal([...w.db.store.keys()].filter((k) => k.startsWith('orders/')).length, 1);
  assert.equal([...w.db.store.keys()].filter((k) => k.includes('/wallet_transactions/')).length, 1);
  assert.equal((await call(w.create, 'bob', orderReq(q.data.quoteId))).code, 'QUOTE_NOT_FOUND', 'un autre client ne rejoue pas le devis');
});

test('commande créée : champs serveur, géographie de dispatch, profil client lu côté serveur', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId, {
    order: { description: 'd', clientName: 'FAUX', clientPhone: '000', pickupCityId: 'pirate', deliveryCityId: 'pirate', cityResolutionStatus: 'resolved', pickupZoneId: 'x', pickupCoordinateSource: 'gps', deliveryCoordinateSource: 'hack', recipientName: 'Bob', status: 'delivered', driverId: 'x', isPaid: false, budget: 1 },
  }));
  const o = w.db.store.get(`orders/${r.data.orderId}`);
  assert.deepEqual([o.clientName, o.clientPhone, o.pickupCityId, o.deliveryCityId, o.pickupZoneId, o.cityResolutionStatus], ['Alice Test', '+2250000000001', 'abengourou', 'abengourou', 'centre', 'resolved']);
  assert.deepEqual([o.pickupCoordinateSource, o.deliveryCoordinateSource, o.recipientName], ['gps', undefined, 'Bob']);
  assert.equal(o.driverId, undefined); assert.equal(o.status, 'pending'); assert.equal(o.isPaid, true); assert.equal(o.budget, 500);
  assert.equal(o.latitude, CENTER.lat); assert.equal(o.destLat, 6.7453); assert.equal(o.deliveryLatitude, o.latitude); assert.equal(o.forSelf, true);
});

test('zone non desservie : refus avant tout débit', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const out = buildCreateOrderFromQuoteCF({ db: w.db, admin, onCall, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, now: () => at(12),
    resolveGeography: async () => { throw Object.assign(new Error('hors villes'), { code: 'outside-service' }); } });
  const r = await call(out, 'alice', orderReq(q.data.quoteId));
  assert.equal(r.code, 'OUTSIDE_SERVICE');
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open');
});

test('services non pris en charge par ce flux : refusés au devis', async () => {
  const w = world();
  for (const serviceType of ['restaurant', 'pharmacie', 'boutique', 'colis']) assert.equal((await w.quote('alice', { serviceType })).code, 'SERVICE_NOT_SUPPORTED');
});

test('devis détourné : autre destination, autre service ou autre mode refusés', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const far = { lat: 6.95, lng: -3.4961 };
  assert.equal((await call(w.create, 'alice', orderReq(q.data.quoteId, { destination: far }))).code, 'QUOTE_MISMATCH');
  assert.equal((await call(w.create, 'alice', orderReq(q.data.quoteId, { serviceType: 'courses' }))).code, 'QUOTE_MISMATCH');
  assert.equal((await call(w.create, 'alice', orderReq(q.data.quoteId, { mode: 'express' }))).code, 'QUOTE_MISMATCH');
  assert.equal((await call(w.create, 'alice', orderReq(q.data.quoteId, { pickup: far }))).code, 'QUOTE_MISMATCH');
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
});

test('tarif devenu supérieur (passage à la nuit) : aucun débit, nouvelle confirmation exigée', async () => {
  const w = world({ nowMs: at(19, 58) });
  const q = await w.quote('alice', {});
  assert.equal(q.data.amount, 500);
  w.setClock(at(20, 1));
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId));
  assert.equal(r.code, 'PRICE_CHANGED');
  assert.deepEqual(r.data, { quotedAmount: 500, currentAmount: 1000 });
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open');
});

test('tarif devenu inférieur (sortie de nuit) : le client paie le moindre des deux', async () => {
  const w = world({ nowMs: at(5, 58) });
  const q = await w.quote('alice', {});
  assert.equal(q.data.amount, 1000);
  w.setClock(at(6, 1));
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId));
  assert.equal(r.data.charged, 500);
  assert.equal(w.db.store.get('clients/alice').wallet, 4500);
});

test('solde insuffisant : aucun débit, devis conservé ; solde jamais négatif', async () => {
  const w = world({ wallet: 300 });
  const q = await w.quote('alice', {});
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId));
  assert.equal(r.code, 'SOLDE_INSUFFISANT'); assert.match(r.message, /^SOLDE_INSUFFISANT:300:500$/);
  assert.equal(w.db.store.get('clients/alice').wallet, 300);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open');
});

test('montant confirmé inférieur au montant à débiter : refusé', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  assert.equal((await call(w.create, 'alice', orderReq(q.data.quoteId, { confirmedAmount: 100 }))).code, 'AMOUNT_NOT_CONFIRMED');
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
});

test('appels non authentifiés refusés, limitation de débit appliquée', async () => {
  const w = world();
  await assert.rejects(call(w.create, null, orderReq('x')), { code: 'unauthenticated' });
  const limited = [];
  const quoteCF = buildQuoteDeliveryCF({ db: w.db, admin, onCall, HttpsError, checkRateLimit: async (...a) => { limited.push(a); } });
  await assert.rejects(call(quoteCF, null, {}), { code: 'unauthenticated' });
  const ok = await call(quoteCF, 'alice', { serviceType: 'livraison', pickup: CENTER, destination: DEST });
  assert.equal(ok.success, true);
  assert.deepEqual(limited[0], ['alice', 'quote_delivery', 30, 60]);
});

test('devis lié à un devis falsifié côté base : montant du document serveur seul fait foi', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId, { amount: 1, quotedAmount: 1, budget: 1 }));
  assert.equal(w.db.store.get(`orders/${r.data.orderId}`).budget, 500);
});

test('compte non client (livreur) ou client supprimé : devis et commande refusés', async () => {
  const w = world();
  w.db.store.set('livreurs/drv', { wallet: 0 });
  w.db.store.set('clients/gone', { wallet: 5000, isDeleted: true });
  const quoteCF = buildQuoteDeliveryCF({ db: w.db, admin, onCall, HttpsError, checkRateLimit: async () => {}, now: () => at(12) });
  assert.equal((await call(quoteCF, 'drv', { serviceType: 'livraison', pickup: CENTER, destination: DEST })).code, 'CLIENT_NOT_FOUND');
  assert.equal((await call(quoteCF, 'gone', { serviceType: 'livraison', pickup: CENTER, destination: DEST })).code, 'ACCOUNT_UNAVAILABLE');
  const q = await w.quote('drv', {});
  assert.equal((await call(w.create, 'drv', orderReq(q.data.quoteId, { paymentMethod: 'cash' }))).code, 'CLIENT_NOT_FOUND');
  assert.equal([...w.db.store.keys()].filter((k) => k.startsWith('orders/')).length, 0);
});

test("paramètres invalides : quoteId absent ou avec chemin, budget d'achat négatif ou non entier", async () => {
  const w = world();
  await assert.rejects(call(w.create, 'alice', {}), { code: 'invalid-argument' });
  await assert.rejects(call(w.create, 'alice', orderReq('a/b')), { code: 'invalid-argument' });
  const q = await w.quote('alice', { serviceType: 'courses' });
  for (const shoppingBudget of [-100, 12.5, '500', NaN, null]) {
    await assert.rejects(call(w.create, 'alice', orderReq(q.data.quoteId, { serviceType: 'courses', shoppingBudget })), { code: 'invalid-argument' }, String(shoppingBudget));
  }
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open');
});

test('mobile money et modes inconnus refusés explicitement (jamais traités comme du cash)', async () => {
  const w = world();
  const q = await w.quote('alice', {});
  for (const paymentMethod of ['orange_money', 'mtn_money', 'wave', 'bitcoin', '', undefined, null]) {
    const r = await call(w.create, 'alice', orderReq(q.data.quoteId, { paymentMethod }));
    assert.equal(r.code, 'PAYMENT_METHOD_UNSUPPORTED', String(paymentMethod));
  }
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open');
});

test('la liste d\'articles d\'une course (description longue) n\'est pas tronquée à 500 caractères', async () => {
  const w = world();
  const q = await w.quote('alice', { serviceType: 'courses' });
  const long = Array.from({ length: 120 }, (_, i) => `${i + 1}. Article numéro ${i + 1}`).join('\n');
  assert.ok(long.length > 1500);
  const r = await call(w.create, 'alice', orderReq(q.data.quoteId, { serviceType: 'courses', order: { description: long } }));
  assert.equal(w.db.store.get(`orders/${r.data.orderId}`).description, long);
});
