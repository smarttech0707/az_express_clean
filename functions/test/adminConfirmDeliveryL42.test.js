'use strict';

// L4.2 — adminConfirmDeliveryCF : aucun crédit à un partenaire fermé (quarantaine, scellé, anonymisé, absent, illisible, lecture en
// erreur). Fonctions réelles sur faux Firestore sérialisé ; données fictives. La concurrence réelle (tombstone créé entre lecture et
// écriture) est prouvée sur l'émulateur : adminConfirmDeliveryL42.emulator.test.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildDeliverOrder } = require('../orderActions');
const { requireSuperAdmin } = require('../adminGuards');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const ts = (ms) => ({ toMillis: () => ms });
const T = Date.parse('2026-07-01T00:00:00Z');
const tomb = (over = {}) => ({ createdAt: ts(T + 1000), state: 'deleting', ...over });
const REQ = 'request-id-00000001';
const J = 'Livraison confirmée par téléphone avec le client';

const v2Order = () => ({
  clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000, budget: 500,
  shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100, acceptedAt: ts(T), createdAt: ts(T),
});
const legacyOrder = () => ({
  clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
  paymentMethod: 'wallet', isPaid: true, budget: 700, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA',
  commissionAmount: 100, acceptedAt: ts(T), createdAt: ts(T),
});
const SHAPES = { v2: v2Order, legacy: legacyOrder };

function world(shape = 'v2', seed = {}) {
  const db = fakeDb({
    'orders/o1': SHAPES[shape](),
    'restaurants/r1': { name: 'Chez Test', wallet: 1000 },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1' },
    'admins/root': { role: 'super', isActive: true },
    'admins/sub': { role: 'sub', isActive: true, permissions: ['commandes'] },
    ...seed,
  });
  const audits = [];
  const fn = buildDeliverOrder({ db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, adminConfirm: true, requireSuperAdmin });
  return { db, audits, confirm: (uid = 'root', over = {}) => fn.run({ auth: authOf(uid), data: { orderId: 'o1', requestId: REQ, justification: J, evidence: 'client_confirmed', ...over } }) };
}
const get = (w, p) => w.db.store.get(p);
const snap = (w) => JSON.stringify([...w.db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
// Instantané hors trace de refus (signalement + champs de revue de la commande) : tout le reste doit être strictement identique.
const core = (w) => JSON.stringify([...w.db.store.entries()].filter(([k]) => !/^reconciliation_flags\//.test(k))
  .map(([k, v]) => (k === 'orders/o1' ? [k, (({ needsReview, reviewReason, reviewFlagId, ...r }) => r)(v)] : [k, v])).sort(([a], [b]) => (a < b ? -1 : 1)));
const journals = (w) => [...w.db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));
const closed = (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED';

test('1. partenaire actif : comportement historique (v2 : produits au partenaire, frais au livreur ; legacy : partenaire crédité)', async () => {
  const v = world('v2');
  await v.confirm();
  assert.equal(get(v, 'orders/o1').status, 'delivered');
  assert.equal(get(v, 'restaurants/r1').wallet, 4500);
  assert.equal(get(v, 'livreurs/dA').wallet, 1400);
  assert.equal(get(v, 'restaurants/r1/wallet_transactions/earning_o1').amount, 3500);
  const l = world('legacy');
  await l.confirm();
  assert.equal(get(l, 'orders/o1').status, 'delivered');
  assert.equal(get(l, 'restaurants/r1').wallet, 1700);
  assert.ok(v.audits.some((a) => a.action === 'admin_confirm_delivery'));
});

const STATES = {
  quarantine: { arrange: (w) => w.db.store.set('account_tombstones/r1', tomb()), cause: 'closing' },
  sealed: { arrange: (w) => w.db.store.set('account_tombstones/r1', tomb({ phase: 'sealed' })), cause: 'sealed' },
  authDeleting: { arrange: (w) => w.db.store.set('account_tombstones/r1', tomb({ authDeletedAtMs: 5 })), cause: 'sealed' },
  anonymized: { arrange: (w) => w.db.store.set('restaurants/r1', { wallet: 1000, isDeleted: true }), cause: 'anonymized' },
  absent: { arrange: (w) => w.db.store.delete('restaurants/r1'), cause: 'absent' },
  unreadable: { arrange: (w) => w.db.store.set('account_tombstones/r1', tomb({ phase: 'bogus' })), cause: 'unreadable' },
};

for (const [name, st] of Object.entries(STATES)) {
  for (const shape of Object.keys(SHAPES)) {
    test(`2-6. partenaire ${name} (${shape}) : aucun crédit, opération refusée en entier, commande inchangée, journaux vides, tombstone intact`, async () => {
      const w = world(shape); st.arrange(w);
      const before = core(w);
      const tombBefore = JSON.stringify(get(w, 'account_tombstones/r1'));
      await assert.rejects(() => w.confirm(), (e) => closed(e) && e.details.cause === st.cause);
      assert.equal(core(w), before, 'aucune écriture hors trace : soldes, journaux, commande, livreur');
      assert.equal(get(w, 'orders/o1').status, 'picked_up');
      assert.equal(get(w, 'livreurs/dA').wallet, 900, 'livreur non crédité non plus');
      assert.equal(journals(w).length, 0, 'aucun journal de règlement positif fictif');
      assert.equal(get(w, 'config/az_wallet'), undefined, 'aucune substitution vers le portefeuille AZ');
      assert.equal(get(w, 'commissions'), undefined);
      assert.equal(JSON.stringify(get(w, 'account_tombstones/r1')), tombBefore, 'compte jamais rouvert ni modifié');
      assert.ok(![...w.db.store.keys()].some((k) => /^order_dispute_decisions\//.test(k)), 'décision non enregistrée : aucun règlement marqué effectué');
      // la dette reste retrouvable : montant du produit toujours sur la commande, jamais marqué réglé
      assert.equal(get(w, 'orders/o1').deliveredAt, undefined);
      assert.equal(get(w, 'reconciliation_flags/o1_deliver_beneficiary_refused').completed, false);
      // 9. retry : même refus, aucun effet de plus
      const after = snap(w);
      await assert.rejects(() => w.confirm(), (e) => closed(e) || /ORDER_UNDER_REVIEW/.test(e.message));
      assert.equal(snap(w), after, 'retry : magasin identique');
    });
  }
}

test('7. erreur de lecture du tombstone ou du profil du partenaire : refus, aucune écriture', async () => {
  for (const failing of ['account_tombstones/r1', 'restaurants/r1']) {
    const w = world('v2');
    const run = w.db.runTransaction.bind(w.db);
    w.db.runTransaction = (cb) => run((tx) => cb({ ...tx, get: async (ref) => { if (ref.path === failing) throw new Error('read down'); return tx.get(ref); }, update: tx.update.bind(tx), set: tx.set.bind(tx), create: tx.create && tx.create.bind(tx) }));
    const before = snap(w);
    await assert.rejects(() => w.confirm(), /read down/);
    assert.equal(snap(w), before, `aucune écriture (${failing})`);
  }
});

test('9-10. retry après succès : aucun double crédit, aucun double journal ; requestId rejoué = no-op', async () => {
  const w = world('v2');
  await w.confirm();
  const after = snap(w);
  await w.confirm(); // même requestId : rejeu idempotent
  assert.equal(snap(w), after);
  assert.equal(get(w, 'restaurants/r1').wallet, 4500);
  await assert.rejects(() => w.confirm('root', { requestId: 'request-id-00000002' })); // autre requestId : commande déjà livrée
  assert.equal(get(w, 'restaurants/r1').wallet, 4500);
  assert.equal(journals(w).filter((k) => k.startsWith('restaurants/r1/')).length, 1);
});

test('partenaire non crédité (paiement cash) : confirmation administrative non bloquée par un partenaire fermé', async () => {
  const w = world('legacy');
  w.db.store.set('orders/o1', { ...legacyOrder(), paymentMethod: 'cash', isPaid: false });
  w.db.store.set('account_tombstones/r1', tomb({ phase: 'sealed' }));
  await w.confirm();
  assert.equal(get(w, 'orders/o1').status, 'delivered');
  assert.equal(get(w, 'restaurants/r1').wallet, 1000, 'aucun crédit au partenaire');
});

test('12. permissions : sous-admin, client, livreur, anonyme, non connecté refusés ; justification, requestId et preuve invalides refusés ; aucune écriture', async () => {
  const w = world('v2');
  const before = snap(w);
  for (const uid of ['sub', 'c1', 'dA', 'nobody']) await assert.rejects(() => w.confirm(uid), undefined, uid);
  await assert.rejects(() => w.confirm('root', { justification: 'court' }), (e) => e.code === 'invalid-argument');
  await assert.rejects(() => w.confirm('root', { requestId: 'x' }), (e) => e.code === 'invalid-argument');
  await assert.rejects(() => w.confirm('root', { evidence: 'inventée' }), (e) => e.code === 'invalid-argument');
  const fn = buildDeliverOrder({ db: w.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, adminConfirm: true, requireSuperAdmin });
  await assert.rejects(() => fn.run({ auth: null, data: { orderId: 'o1', requestId: REQ, justification: J, evidence: 'client_confirmed' } }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => fn.run({ auth: { uid: 'root', token: { firebase: { sign_in_provider: 'anonymous' } } }, data: { orderId: 'o1', requestId: REQ, justification: J, evidence: 'client_confirmed' } }), (e) => e.code === 'unauthenticated');
  assert.equal(snap(w), before);
});

test('la vérification du bénéficiaire se fait DANS la transaction, avant toute écriture (câblage)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'orderActions.js'), 'utf8');
  const i = src.indexOf('await assertBeneficiariesCreditable(tx, db, HttpsError');
  const firstWrite = src.indexOf('tx.update(', src.indexOf('runLifecycleTransaction(db, async (tx) => {', src.indexOf('function buildDeliverOrder')));
  assert.ok(i > 0 && firstWrite > i, 'la garde précède la première écriture de la transaction de livraison');
});
