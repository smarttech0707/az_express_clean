'use strict';

// L4 — clearBeneficiaryReview (adminBillingCF), verrou de revue et lectures en erreur, sur faux Firestore ; données fictives.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildPayOrderFromWallet, buildDeliverOrder, buildCancelOrder } = require('../orderActions');
const { buildAdminBilling } = require('../adminBilling');
const { requireSuperAdmin } = require('../adminGuards');
const { calculateCommission } = require('../dispatch');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const J = 'Bénéficiaire régularisé après vérification du dossier';
const ts = (ms) => ({ toMillis: () => ms });
const T = Date.parse('2026-07-01T00:00:00Z');
const tomb = (over = {}) => ({ createdAt: ts(T + 1000), state: 'deleting', ...over });

function world(seed = {}) {
  const db = fakeDb({
    'orders/o1': { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: false, status: 'accepted', createdAt: ts(T) },
    'clients/c1': { wallet: 1000 }, 'livreurs/d1': { wallet: 200 },
    'admins/root': { role: 'super', isActive: true }, 'admins/sub': { role: 'sub', isActive: true, permissions: ['commandes'] },
    ...seed,
  });
  const audits = [];
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission };
  return {
    db, audits,
    pay: () => buildPayOrderFromWallet({ ...common, onCall: oc }).run({ auth: authOf('c1'), data: { orderId: 'o1' } }),
    clear: (uid = 'root', over = {}) => buildAdminBilling({ ...common, onCall: oc, requireSuperAdmin })
      .run({ auth: authOf(uid), data: { action: 'clearBeneficiaryReview', orderId: 'o1', justification: J, ...over } }),
  };
}
const get = (w, p) => w.db.store.get(p);
const snap = (w) => JSON.stringify([...w.db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
const lockedOrder = { clientId: 'c1', driverId: 'd1', budget: 500, isPaid: false, status: 'accepted', createdAt: ts(T), needsReview: true, reviewReason: 'beneficiary_closed' };

test('clearBeneficiaryReview : bénéficiaire encore scellé -> levée REFUSÉE (BENEFICIARY_STILL_CLOSED), commande toujours verrouillée, rien d’écrit', async () => {
  for (const phase of ['sealed', 'closing']) {
    const w = world({ 'account_tombstones/d1': tomb({ phase }) });
    await assert.rejects(() => w.pay(), (e) => e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED');
    assert.equal(get(w, 'reconciliation_flags/o1_pay_beneficiary_refused').status, 'open');
    const before = snap(w);
    await assert.rejects(() => w.clear(), (e) => /BENEFICIARY_STILL_CLOSED/.test(e.message));
    assert.equal(snap(w), before, 'aucune écriture : ni levée, ni crédit, ni réouverture');
    await assert.rejects(() => w.pay(), (e) => e.details.code === 'ORDER_UNDER_REVIEW');
    assert.equal(get(w, 'livreurs/d1').wallet, 200);
  }
});

test('clearBeneficiaryReview : bénéficiaire anonymisé / absent / illisible -> levée refusée', async () => {
  const cases = { anonymized: { 'livreurs/d1': { wallet: 200, isDeleted: true } }, absent: null, unreadable: { 'account_tombstones/d1': tomb({ phase: 'bogus' }) } };
  for (const [name, seed] of Object.entries(cases)) {
    const w = world(seed || {});
    if (name === 'absent') w.db.store.delete('livreurs/d1');
    await assert.rejects(() => w.pay(), (e) => e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED', name);
    const before = snap(w);
    await assert.rejects(() => w.clear(), (e) => /BENEFICIARY_STILL_CLOSED/.test(e.message), name);
    assert.equal(snap(w), before, name);
  }
});

test('clearBeneficiaryReview : refus fait à tort (bénéficiaire redevenu actif) -> levée, aucun crédit rétroactif, tombstone intact ; rejeu sans effet ; paiement ensuite une seule fois', async () => {
  const w = world({ 'account_tombstones/d1': tomb({ phase: 'sealed' }) });
  await assert.rejects(() => w.pay(), (e) => e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED');
  w.db.store.delete('account_tombstones/d1'); // simulation d'un refus erroné : le bénéficiaire est en réalité actif
  const res = await w.clear();
  assert.equal(res.replay, false);
  assert.equal(get(w, 'orders/o1').needsReview, false);
  assert.equal(get(w, 'orders/o1').reviewReason, undefined);
  assert.equal(get(w, 'orders/o1').reviewClearedBy, 'root');
  // L4.6 (M-3) : levée de verrou ≠ clôture de créance — le signalement reste ouvert, seule la levée est tracée.
  assert.equal(get(w, 'reconciliation_flags/o1_pay_beneficiary_refused').status, 'open');
  assert.equal(get(w, 'reconciliation_flags/o1_pay_beneficiary_refused').lockLifted, true);
  assert.equal(get(w, 'reconciliation_flags/o1_pay_beneficiary_refused').lockLiftedBy, 'root');
  assert.equal(get(w, 'livreurs/d1').wallet, 200, 'aucun crédit rétroactif à la levée');
  assert.equal(get(w, 'clients/c1').wallet, 1000);
  const after = snap(w);
  assert.equal((await w.clear()).replay, true);
  assert.equal(snap(w), after, 'rejeu : aucune écriture');
  await w.pay();
  assert.equal(get(w, 'clients/c1').wallet, 500);
  assert.equal(get(w, 'livreurs/d1').wallet, 700);
  await assert.rejects(() => w.pay());
  assert.equal(get(w, 'livreurs/d1').wallet, 700, 'aucun double crédit');
  assert.ok(w.audits.some((a) => a.action === 'admin_billing_clearBeneficiaryReview'));
});

test('clearBeneficiaryReview : revue sans signalement de refus vérifiable -> levée refusée (BENEFICIARY_NOT_VERIFIABLE)', async () => {
  const w = world({ 'orders/o1': lockedOrder });
  const before = snap(w);
  await assert.rejects(() => w.clear(), (e) => /BENEFICIARY_NOT_VERIFIABLE/.test(e.message));
  assert.equal(snap(w), before);
});

test('clearBeneficiaryReview : permissions (sous-admin, client, non connecté refusés) et justification obligatoire', async () => {
  const w = world({ 'orders/o1': lockedOrder });
  const before = snap(w);
  await assert.rejects(() => w.clear('sub'));
  await assert.rejects(() => w.clear('c1'));
  await assert.rejects(() => w.clear('root', { justification: 'court' }), (e) => e.code === 'invalid-argument');
  await assert.rejects(() => buildAdminBilling({ db: w.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, requireSuperAdmin, calculateCommission })
    .run({ auth: null, data: { action: 'clearBeneficiaryReview', orderId: 'o1', justification: J } }), (e) => e.code === 'unauthenticated');
  assert.equal(snap(w), before);
});

test('clearBeneficiaryReview : revue « crédit non versé » non levable ; commande sans revue refusée ; commande inconnue', async () => {
  const omitted = world({ 'orders/o1': { ...lockedOrder, reviewReason: 'beneficiary_credit_omitted' } });
  const before = snap(omitted);
  await assert.rejects(() => omitted.clear(), (e) => /REVIEW_NOT_CLEARABLE/.test(e.message));
  assert.equal(snap(omitted), before);
  const none = world();
  await assert.rejects(() => none.clear(), (e) => e.code === 'failed-precondition');
  await assert.rejects(() => none.clear('root', { orderId: 'nope' }), (e) => e.code === 'not-found');
});

test('verrou de revue : livraison refusée ORDER_UNDER_REVIEW, annulation toujours possible (le client reste remboursable)', async () => {
  const w = world({ 'orders/o1': { ...lockedOrder, paymentMethod: 'wallet', isPaid: true } });
  const deliver = buildDeliverOrder({ db: w.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {} });
  await assert.rejects(() => deliver.run({ auth: authOf('d1'), data: { orderId: 'o1' } }), (e) => e.details.code === 'ORDER_UNDER_REVIEW');
  const cancel = buildCancelOrder({ db: w.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission });
  const res = await cancel.run({ auth: authOf('c1'), data: { orderId: 'o1' } });
  assert.deepEqual(res, { success: true });
  assert.equal(get(w, 'orders/o1').status, 'cancelled');
});

test('lecture en erreur sur un bénéficiaire : l’erreur se propage, aucun crédit ni débit, jamais pris pour un compte actif', async () => {
  const w = world();
  const real = w.db.collection.bind(w.db);
  w.db.collection = (name) => {
    const c = real(name);
    if (name !== 'livreurs') return c;
    return { ...c, doc: (id) => ({ ...c.doc(id), get: async () => { throw new Error('read down'); } }) };
  };
  // la garde lit via tx.get : on simule la panne sur le tombstone du bénéficiaire
  const real2 = w.db.runTransaction.bind(w.db);
  w.db.runTransaction = (cb) => real2((tx) => cb({
    ...tx, get: async (ref) => { if (ref.path === 'account_tombstones/d1') throw new Error('tombstone read down'); return tx.get(ref); },
    update: tx.update.bind(tx), set: tx.set.bind(tx),
  }));
  const before = snap(w);
  await assert.rejects(() => w.pay(), /read down/);
  assert.equal(snap(w), before);
});

test('tombstone du bénéficiaire illisible : paiement refusé, jamais crédité', async () => {
  const w = world({ 'account_tombstones/d1': tomb({ phase: 'bogus' }) }); // phase invalide = tombstone illisible
  await assert.rejects(() => w.pay(), (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED' && e.details.cause === 'unreadable');
  assert.equal(get(w, 'livreurs/d1').wallet, 200);
  assert.equal(get(w, 'clients/c1').wallet, 1000);
});

test('closureGuard : tombstone illisible refusé même quand onClosed vaut « skip » (une lecture douteuse n’autorise jamais d’omission silencieuse ni de crédit)', async () => {
  const { closureGuard } = require('../accountClosureActor');
  const w = world({ 'account_tombstones/d1': tomb({ phase: 'bogus' }) });
  await assert.rejects(() => w.db.runTransaction((tx) => closureGuard(tx, w.db, HttpsError, {
    fn: 'cancelOrderCF', uid: 'c1', engagedAtMs: T, beneficiaries: [{ collection: 'livreurs', id: 'd1', onQuarantine: 'skip', onClosed: 'skip' }],
  })), (e) => e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED' && e.details.cause === 'unreadable');
});
