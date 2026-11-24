'use strict';

// Mission 7E-90 (lot 2B) : le tombstone / la suppression du compte sont relus DANS la transaction qui crée la commande
// et débite le wallet (createOrderFromQuoteCF, payBoutiqueOrderCF, payBoutiqueOrderCashCF). Tests UNITAIRES sur faux Firestore :
// ils prouvent la logique de refus, l'absence d'écriture et l'ordre lectures-avant-écritures, PAS l'isolation transactionnelle
// réelle (voir walletDebitQuarantine.emulator.test.js).
const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeDb } = require('./fakeFirestore');
const { world: boutiqueWorld } = require('./billingWorld');
const { buildCreateOrderFromQuoteCF, createQuote } = require('../deliveryQuote');

// Comme Firestore : toute lecture transactionnelle APRÈS une écriture est une erreur.
function strict(db, hooks = {}) {
  const run = db.runTransaction;
  db.runTransaction = (cb) => run.call(db, async (tx) => {
    let wrote = false;
    const mark = (fn) => (...a) => { wrote = true; return fn(...a); };
    if (hooks.beforeCallback) await hooks.beforeCallback();
    return cb({
      get: async (r) => {
        if (wrote) throw new Error(`lecture transactionnelle après écriture : ${r.path}`);
        if (hooks.failRead && hooks.failRead(r.path)) throw new Error(`lecture impossible ${r.path}`);
        return tx.get(r);
      },
      update: mark(tx.update), set: mark(tx.set), create: mark(tx.create),
    });
  });
  return db;
}
const snapshot = (db) => JSON.stringify([...db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));

// ───────────────────────────── createOrderFromQuoteCF ─────────────────────────────
const CENTER = { lat: 6.7273, lng: -3.4961 };
const DEST = { lat: 6.7453, lng: -3.4961 };
const NOON = Date.UTC(2026, 5, 1, 12, 0);
const admin = { firestore: { FieldValue: { serverTimestamp: () => 'TS' } } };
class HttpsError extends Error { constructor(code, message) { super(message); this.code = code; } }

function quoteWorld(seed = {}, hooks = {}) {
  const db = strict(fakeDb({ 'clients/alice': { wallet: 5000, name: 'Alice', phone: '+2250000000001' }, ...seed }), hooks);
  let seq = 0;
  const create = buildCreateOrderFromQuoteCF({
    db, admin, onCall: (h) => h, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {},
    now: () => NOON, newOrderId: () => `order${seq++}`,
    resolveGeography: async () => ({ pickupCityId: 'abengourou', deliveryCityId: 'abengourou', pickupZoneId: 'centre', deliveryZoneId: 'centre', cityResolutionStatus: 'resolved' }),
  });
  const quote = () => createQuote({ db, admin, uid: 'alice', data: { serviceType: 'livraison', pickup: CENTER, destination: DEST }, nowMs: NOON });
  const req = (quoteId, extra = {}) => ({ auth: { uid: 'alice' }, data: { quoteId, serviceType: 'livraison', mode: 'standard', pickup: CENTER, destination: DEST, paymentMethod: 'wallet', order: { description: 'colis' }, ...extra } });
  return { db, create, quote, req };
}

test('quote : client actif → commande créée et wallet débité (non-régression)', async () => {
  const w = quoteWorld();
  const q = await w.quote();
  const r = await w.create(w.req(q.data.quoteId));
  assert.equal(r.success, true);
  assert.equal(w.db.store.get('clients/alice').wallet, 4500);
});

for (const [label, patch] of [['quarantaine (deletionRequested)', { deletionRequested: true }], ['profil anonymisé (isDeleted)', { isDeleted: true }]]) {
  for (const method of ['wallet', 'cash']) {
    test(`quote : ${label}, paiement ${method} → refusé, aucune écriture`, async () => {
      const w = quoteWorld({ 'clients/alice': { wallet: 5000, ...patch } });
      const q = await w.quote();
      const before = snapshot(w.db);
      const r = await w.create(w.req(q.data.quoteId, { paymentMethod: method }));
      assert.equal(r.success, false);
      assert.equal(snapshot(w.db), before, 'ni débit, ni commande, ni devis consommé');
    });
  }
}

for (const method of ['wallet', 'cash']) {
  test(`quote : tombstone existant sur un profil intact, paiement ${method} → refusé par la garde transactionnelle, zéro écriture`, async () => {
    const w = quoteWorld({ 'account_tombstones/alice': { state: 'deleting' } });
    const q = await w.quote();
    const before = snapshot(w.db);
    await assert.rejects(() => w.create(w.req(q.data.quoteId, { paymentMethod: method })), (e) => e.code === 'failed-precondition' && /suppression/.test(e.message));
    assert.equal(snapshot(w.db), before);
  });
}

test('quote : quarantaine posée ENTRE les contrôles d\'entrée et la transaction → refusée, aucun débit', async () => {
  let w;
  w = quoteWorld({}, { beforeCallback: async () => { w.db.store.set('account_tombstones/alice', { state: 'deleting' }); } });
  const q = await w.quote();
  await assert.rejects(() => w.create(w.req(q.data.quoteId)), (e) => e.code === 'failed-precondition');
  assert.equal(w.db.store.get('clients/alice').wallet, 5000);
  assert.equal([...w.db.store.keys()].filter((k) => k.startsWith('orders/')).length, 0);
  assert.equal(w.db.store.get(`tariff_quotes/${q.data.quoteId}`).status, 'open', 'devis non consommé');
});

test('quote : lecture du tombstone impossible → fail-closed, solde et devis intacts', async () => {
  const w = quoteWorld({}, { failRead: (p) => p === 'account_tombstones/alice' });
  const q = await w.quote();
  const before = snapshot(w.db);
  await assert.rejects(() => w.create(w.req(q.data.quoteId)), /lecture impossible/);
  assert.equal(snapshot(w.db), before);
});

test('quote : rejeu d\'un devis DÉJÀ utilisé (réponse perdue) → même commande rendue, aucun nouveau débit, même après quarantaine', async () => {
  const w = quoteWorld();
  const q = await w.quote();
  const first = await w.create(w.req(q.data.quoteId));
  assert.equal(first.success, true);
  w.db.store.set('account_tombstones/alice', { state: 'deleting' });
  const second = await w.create(w.req(q.data.quoteId));
  assert.equal(second.success, true);
  assert.equal(second.data.replayed, true);
  assert.equal(second.data.orderId, first.data.orderId);
  assert.equal(w.db.store.get('clients/alice').wallet, 4500, 'un seul débit');
});

test('quote : après un refus de quarantaine, nouvelle tentative → toujours refusée (pas d\'effet partiel)', async () => {
  const w = quoteWorld({ 'account_tombstones/alice': { state: 'deleting' } });
  const q = await w.quote();
  const before = snapshot(w.db);
  for (let i = 0; i < 3; i++) await assert.rejects(() => w.create(w.req(q.data.quoteId)));
  assert.equal(snapshot(w.db), before);
});

// ───────────────────────────── payBoutiqueOrderCF / payBoutiqueOrderCashCF ─────────────────────────────
const PAY = { productId: 'b1', qty: 1, deliveryLat: 6.7, deliveryLng: -3.5, acceptedTotal: 5500 };
const orderKeys = (h) => [...h.db.store.keys()].filter((k) => k.startsWith('orders/') || k.startsWith('boutique_orders/'));
function bWorld(seed = {}, hooks = {}) {
  const h = boutiqueWorld(seed);
  strict(h.db, hooks);
  h.mode('accepted_only');
  return h;
}

for (const fn of ['payBoutique', 'payBoutiqueCash']) {
  test(`${fn} : client actif → achat accepté (non-régression)`, async () => {
    const h = bWorld();
    const r = await h.call(fn, 'c1', PAY);
    assert.ok(r.orderId);
    assert.equal(h.get('boutique_products/b1').stock, 9);
    if (fn === 'payBoutique') assert.equal(h.w('clients/c1'), 4500);
  });

  for (const [label, seed] of [
    ['tombstone existant', { 'account_tombstones/c1': { state: 'deleting' } }],
    ['client en suppression (deletionRequested)', { 'clients/c1': { wallet: 10000, deletionRequested: true } }],
    ['client anonymisé (isDeleted)', { 'clients/c1': { wallet: 10000, isDeleted: true } }],
  ]) {
    test(`${fn} : ${label} → refusé, ni débit, ni stock, ni commande, ni crédit vendeur`, async () => {
      const h = bWorld(seed);
      const before = snapshot(h.db);
      await assert.rejects(() => h.call(fn, 'c1', PAY), (e) => e.code === 'failed-precondition');
      assert.equal(snapshot(h.db), before);
      assert.deepEqual(orderKeys(h), []);
    });
  }

  test(`${fn} : quarantaine posée ENTRE les contrôles d'entrée et la transaction → refusé, stock et solde intacts`, async () => {
    let h;
    h = bWorld({}, { beforeCallback: async () => { h.db.store.set('account_tombstones/c1', { state: 'deleting' }); } });
    await assert.rejects(() => h.call(fn, 'c1', PAY), (e) => e.code === 'failed-precondition');
    assert.equal(h.get('boutique_products/b1').stock, 10);
    assert.equal(h.w('clients/c1'), 10000);
    assert.deepEqual(orderKeys(h), []);
  });

  test(`${fn} : lecture du tombstone impossible → fail-closed, aucun état partiel`, async () => {
    const h = bWorld({}, { failRead: (p) => p === 'account_tombstones/c1' });
    const before = snapshot(h.db);
    await assert.rejects(() => h.call(fn, 'c1', PAY), /lecture impossible/);
    assert.equal(snapshot(h.db), before);
  });

  test(`${fn} : nouvelle tentative après refus → toujours refusée, rien d'écrit`, async () => {
    const h = bWorld({ 'account_tombstones/c1': { state: 'deleting' } });
    const before = snapshot(h.db);
    for (let i = 0; i < 3; i++) await assert.rejects(() => h.call(fn, 'c1', PAY));
    assert.equal(snapshot(h.db), before);
  });
}

test('payBoutique (wallet) : vendeur supprimé/anonymisé → refusé avant tout débit (garde vendeur)', async () => {
  const h = bWorld({ 'sellers/s1': { wallet: 0, name: 'Vendeur', type: 'boutique', lat: 6.7, lng: -3.5, isDeleted: true } });
  const before = snapshot(h.db);
  await assert.rejects(() => h.call('payBoutique', 'c1', PAY), (e) => e.code === 'failed-precondition');
  assert.equal(snapshot(h.db), before);
});

test('payBoutiqueCash : aucun wallet n\'est jamais touché (client, vendeur) — flux espèces ≠ débit wallet', async () => {
  const h = bWorld();
  await h.call('payBoutiqueCash', 'c1', PAY);
  assert.equal(h.w('clients/c1'), 10000);
  assert.equal(h.w('sellers/s1'), 0);
});

test('payBoutique : échec transactionnel (stock épuisé) → aucun solde partiellement modifié', async () => {
  const h = bWorld({ 'boutique_products/b1': { sellerId: 's1', name: 'Riz', category: 'A', price: 5000, stock: 0 } });
  const before = snapshot(h.db);
  await assert.rejects(() => h.call('payBoutique', 'c1', PAY), /STOCK_EPUISE/);
  assert.equal(snapshot(h.db), before);
});
