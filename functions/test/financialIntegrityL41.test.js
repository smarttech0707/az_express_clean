'use strict';

// L4.1 — intégrité financière : sommes omises rapprochables et jamais perdues / doublées, acteur ≠ bénéficiaire, vendeur marketplace
// fermé, états ambigus. Faux Firestore sérialisé ; données fictives. Un signalement n'est JAMAIS tenu pour une réserve financière :
// ces tests vérifient que l'argent ne bouge pas (conservation de la somme des soldes) et que la trace permet de le retrouver.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildCancelOrder, buildDeliverOrder } = require('../orderActions');

const oc = (...a) => ({ run: a[a.length - 1] });
const ts = (ms) => ({ toMillis: () => ms });
const T = Date.parse('2026-07-01T00:00:00Z');
const tomb = (over = {}) => ({ createdAt: ts(T + 1000), state: 'deleting', ...over });
const common = (db) => ({ db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission: async () => 100 });
const get = (db, p) => db.store.get(p);
const snap = (db) => JSON.stringify([...db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
const wallets = (db) => [...db.store.entries()].filter(([k]) => /^(clients|livreurs|sellers|restaurants)\/[^/]+$/.test(k)).reduce((s, [, v]) => s + Number(v.wallet || 0), 0);
const journals = (db) => [...db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));

const cancelWorld = (seed = {}, orderOver = {}) => fakeDb({
  'orders/o1': {
    clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', isPaid: true, budget: 1000, createdAt: ts(T),
    commissionStatus: 'charged', commissionPayerId: 'd1', commissionAmount: 100, ...orderOver,
  },
  'clients/c1': { wallet: 0 }, 'livreurs/d1': { wallet: 500 }, ...seed,
});
const cancel = (db, uid = 'c1') => buildCancelOrder(common(db)).run({ auth: { uid }, data: { orderId: 'o1' } });

test('somme omise : livreur fermé (scellé, quarantaine, anonymisé, absent) -> client remboursé, livreur non crédité, commission restée côté AZ, signalement rapprochable', async () => {
  const cases = {
    sealed: { 'account_tombstones/d1': tomb({ phase: 'sealed' }) },
    closing: { 'account_tombstones/d1': tomb() },
    anonymized: { 'livreurs/d1': { wallet: 500, isDeleted: true } },
    absent: null,
  };
  for (const [name, seed] of Object.entries(cases)) {
    const db = cancelWorld(seed || {});
    if (name === 'absent') db.store.delete('livreurs/d1');
    const walletsBefore = wallets(db);
    await cancel(db);
    // conservation : seul le remboursement du client (1000) entre dans les portefeuilles ; aucun crédit au bénéficiaire fermé
    assert.equal(wallets(db) - walletsBefore, 1000, name);
    assert.equal(get(db, 'clients/c1').wallet, 1000, name);
    if (name !== 'absent') assert.equal(get(db, 'livreurs/d1').wallet, 500, name);
    assert.equal(journals(db).filter((k) => k.startsWith('livreurs/d1/')).length, 0, `aucun journal de crédit au livreur (${name})`);
    const order = get(db, 'orders/o1');
    assert.equal(order.commissionStatus, 'charged', 'la commission reste acquise : rien n’est rendu');
    assert.equal(order.reviewReason, 'beneficiary_credit_omitted');
    const flag = get(db, `reconciliation_flags/${order.reviewFlagId}`);
    assert.equal(flag.orderId, 'o1'); assert.equal(flag.currency, 'XOF'); assert.equal(flag.kind, 'commission_refund_omitted');
    assert.equal(flag.status, 'open');
    assert.deepEqual(flag.parties.map((p) => [p.collection, p.id, p.amountWithheld, p.sourceJournalId]), [['livreurs', 'd1', 100, 'commission_o1_d1']]);
    assert.ok(!JSON.stringify(flag).match(/phone|email|"name"|address/i));
  }
});

test('somme omise : aucun double règlement ni perte au rejeu (annulation unique, signalement inchangé, aucun crédit supplémentaire)', async () => {
  const db = cancelWorld({ 'account_tombstones/d1': tomb({ phase: 'sealed' }) });
  await cancel(db);
  const after = snap(db);
  await assert.rejects(() => cancel(db));
  assert.equal(snap(db), after, 'rejeu : magasin strictement identique (aucun second remboursement, aucun second signalement)');
});

test('acteur ≠ bénéficiaire : le remboursement PROPRE du client en quarantaine n’est pas suspendu, le crédit du livreur (bénéficiaire) actif est versé', async () => {
  const db = cancelWorld({ 'account_tombstones/c1': tomb() });
  await cancel(db);
  assert.equal(get(db, 'clients/c1').wallet, 1000, 'remboursement propre de l’acteur en quarantaine');
  assert.equal(get(db, 'livreurs/d1').wallet, 600, 'bénéficiaire actif crédité');
  assert.equal(get(db, 'orders/o1').commissionStatus, 'refunded');
  assert.equal(get(db, 'account_tombstones/c1').epoch, 1);
  assert.equal(get(db, 'orders/o1').needsReview, undefined, 'aucune revue : rien d’omis');
});

test('acteur ≠ bénéficiaire : le client en quarantaine ET le livreur en quarantaine -> client remboursé, livreur non crédité', async () => {
  const db = cancelWorld({ 'account_tombstones/c1': tomb(), 'account_tombstones/d1': tomb() });
  await cancel(db);
  assert.equal(get(db, 'clients/c1').wallet, 1000);
  assert.equal(get(db, 'livreurs/d1').wallet, 500);
  assert.equal(get(db, 'orders/o1').reviewReason, 'beneficiary_credit_omitted');
});

test('gain propre du livreur acteur en quarantaine (engagé avant) : non suspendu par la quarantaine', async () => {
  const db = fakeDb({
    'orders/o1': { clientId: 'c1', driverId: 'd1', status: 'accepted', paymentMethod: 'wallet', isPaid: true, budget: 1000, acceptedAt: ts(T), createdAt: ts(T) },
    'livreurs/d1': { wallet: 0 }, 'account_tombstones/d1': tomb(),
  });
  await buildDeliverOrder(common(db)).run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } });
  assert.equal(get(db, 'orders/o1').status, 'delivered');
  assert.ok(get(db, 'livreurs/d1').wallet > 0, 'gain propre versé à l’acteur');
});

test('marketplace : vendeur absent, scellé ou anonymisé -> annulation REFUSÉE, aucun débit / remboursement / compensation, trace seulement', async () => {
  const mk = (sellerSeed) => cancelWorld({
    'sellers/s1': { wallet: 700 }, ...sellerSeed,
  }, { sellerType: 'seller', sellerId: 's1', commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined });
  const cases = {
    absent: (db) => db.store.delete('sellers/s1'),
    sealed: (db) => db.store.set('account_tombstones/s1', tomb({ phase: 'sealed' })),
    anonymized: (db) => db.store.set('sellers/s1', { wallet: 700, isDeleted: true }),
  };
  for (const [name, arrange] of Object.entries(cases)) {
    const db = mk({}); arrange(db);
    const stripped = () => JSON.stringify([...db.store.entries()].filter(([k]) => !/^reconciliation_flags\//.test(k)).map(([k, v]) => (k === 'orders/o1' ? [k, (({ needsReview, reviewReason, reviewFlagId, ...r }) => r)(v)] : [k, v])).sort(([a], [b]) => (a < b ? -1 : 1)));
    const before = stripped();
    await assert.rejects(() => cancel(db), (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED', name);
    assert.equal(stripped(), before, `${name} : aucune écriture financière`);
    assert.equal(get(db, 'orders/o1').status, 'accepted');
    assert.equal(get(db, 'clients/c1').wallet, 0);
    assert.equal(get(db, 'reconciliation_flags/o1_cancel_beneficiary_refused').completed, false);
  }
});

test('marketplace : vendeur en quarantaine -> débit de restitution appliqué (inchangé), epoch+1, client remboursé', async () => {
  const db = cancelWorld({ 'sellers/s1': { wallet: 700 }, 'account_tombstones/s1': tomb() },
    { sellerType: 'seller', sellerId: 's1', commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined });
  await cancel(db);
  assert.equal(get(db, 'clients/c1').wallet, 1000);
  assert.equal(get(db, 'sellers/s1').wallet, 0);
  assert.equal(get(db, 'account_tombstones/s1').epoch, 1);
});

test('états ambigus : tombstone illisible ou lecture en erreur sur le bénéficiaire -> annulation sans aucun crédit au bénéficiaire (illisible = refus complet)', async () => {
  const db = cancelWorld({ 'account_tombstones/d1': tomb({ phase: 'bogus' }) });
  const before = snap(db);
  await assert.rejects(() => cancel(db), (e) => e.details && e.details.cause === 'unreadable');
  assert.equal(JSON.stringify([...db.store.entries()].filter(([k]) => !/^reconciliation_flags\//.test(k)).map(([k, v]) => (k === 'orders/o1' ? [k, (({ needsReview, reviewReason, reviewFlagId, ...r }) => r)(v)] : [k, v])).sort(([a], [b]) => (a < b ? -1 : 1))), before);
  const db2 = cancelWorld({});
  const run = db2.runTransaction.bind(db2);
  db2.runTransaction = (cb) => run((tx) => cb({ ...tx, get: async (ref) => { if (ref.path === 'account_tombstones/d1') throw new Error('read down'); return tx.get(ref); }, update: tx.update.bind(tx), set: tx.set.bind(tx) }));
  const before2 = snap(db2);
  await assert.rejects(() => cancel(db2), /read down/);
  assert.equal(snap(db2), before2, 'aucune écriture');
});
