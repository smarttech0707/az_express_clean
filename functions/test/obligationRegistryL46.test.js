'use strict';

// L4.6 — les signalements écrits par L4 (`beneficiary_closed`, `beneficiary_closed_refused`) sont lus par le moteur d'obligations ;
// la levée d'un verrou (clearBeneficiaryReview) n'est jamais une clôture de créance. Moteur pur + writers réels sur faux Firestore ;
// données fictives, aucun Firestore réel.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const engine = require('../accountObligations');
const { buildAdminBilling } = require('../adminBilling');
const { requireSuperAdmin } = require('../adminGuards');
const { recordBeneficiaryRefusal, flagPartyFields } = require('../accountClosureActor');
const { calculateCommission } = require('../dispatch');

const { evaluateAccountObligations: strict, requiredQueries, INSPECTOR_TERMINAL_STATUSES, STATE, TYPES } = engine;
const TERMINAL = INSPECTOR_TERMINAL_STATUSES.accountDeletionScope;

const evaluate = (role, id, flags, over = {}) => {
  const o = { role, ids: [id], orders: [], settlements: [], flags, terminalStatuses: TERMINAL, walletDebits: [], ...over };
  const req = requiredQueries(role, o.ids);
  o.reads = {};
  for (const n of ['orders', 'settlements', 'flags']) {
    o.reads[n] = { queries: req[n].map((q, i) => ({ ...q, limit: 201, size: i === 0 ? o[n].length : 0 })) };
  }
  return strict(o);
};
const flagsOf = (r) => r.obligations.filter((i) => i.source === 'reconciliation_flag');

const omitted = (over = {}) => ({
  orderId: 'o1', type: 'beneficiary_closed', status: 'open', needsReview: true, currency: 'XOF', kind: 'commission_refund_omitted',
  parties: [{ collection: 'livreurs', id: 'd1', state: 'sealed', reason: 'closed', amountWithheld: 100, sourceJournalId: 'commission_o1_d1' }],
  driverId: 'd1', createdAtMs: 1, ...over,
});
const refused = (over = {}) => ({
  orderId: 'o1', type: 'beneficiary_closed_refused', operation: 'payOrderFromWalletCF', status: 'open', needsReview: true, completed: false,
  beneficiary: { collection: 'livreurs', id: 'd1', state: 'sealed' }, driverId: 'd1', createdAtMs: 1, ...over,
});
const doc = (id, data) => ({ id, data });

test('signalement « crédit omis » avec parties[] : reconnu, bénéficiaire, montant 100 XOF, créance de commission, bloquant', () => {
  const r = evaluate('livreur', 'd1', [doc('o1_beneficiary_closed', omitted())]);
  assert.equal(r.blocking, true);
  const [f] = flagsOf(r);
  assert.equal(f.type, TYPES.RECONCILIATION_FLAG_OPEN);
  assert.equal(f.state, STATE.REVIEW);
  assert.equal(f.reason, 'flag_open:beneficiary_closed');
  assert.equal(f.amount, 100);
  assert.equal(f.currency, 'XOF');
  assert.equal(f.claim, 'commission');
  assert.equal(f.party, 'driver');
});

test('plusieurs bénéficiaires : chaque compte voit SA part (livreur 100, vendeur 400) et pas celle de l’autre', () => {
  const two = omitted({
    parties: [
      { collection: 'livreurs', id: 'd1', state: 'sealed', reason: 'c', amountWithheld: 100, sourceJournalId: 'commission_o1_d1' },
      { collection: 'sellers', id: 's1', state: 'anonymized', reason: 'c', amountWithheld: 400, sourceJournalId: 'commission_o1_s1' },
    ],
    sellerId: 's1',
  });
  assert.equal(flagsOf(evaluate('livreur', 'd1', [doc('o1_beneficiary_closed', two)]))[0].amount, 100);
  assert.equal(flagsOf(evaluate('seller', 's1', [doc('o1_beneficiary_closed', two)]))[0].amount, 400);
  const other = flagsOf(evaluate('client', 'c9', [doc('o1_beneficiary_closed', two)]))[0];
  assert.equal(other.type, TYPES.UNRELATED_DOCUMENT);
  assert.equal(other.state, STATE.AMBIGUOUS);
});

test('signalement historique SANS champ plat : bénéficiaire lu dans la structure imbriquée, jamais ignoré', () => {
  const hist = omitted(); delete hist.driverId;
  const r = evaluate('livreur', 'd1', [doc('o1_beneficiary_closed', hist)]);
  assert.equal(flagsOf(r)[0].reason, 'flag_open:beneficiary_closed');
  assert.equal(flagsOf(r)[0].amount, 100);
});

test('trace de refus (beneficiary_closed_refused) : reconnue, sans montant inventé, bloquante', () => {
  const [f] = flagsOf(evaluate('livreur', 'd1', [doc('o1_pay_beneficiary_refused', refused())]));
  assert.equal(f.state, STATE.REVIEW);
  assert.equal(f.reason, 'flag_open:beneficiary_closed_refused');
  assert.equal(f.amount, null);
  assert.equal(f.claim, null);
});

test('incomplets / ambigus : montant, devise, journal source, bénéficiaire, commande manquants => ambigu bloquant, jamais réglable', () => {
  const cases = [
    ['flag_amount_invalid', omitted({ parties: [{ collection: 'livreurs', id: 'd1', sourceJournalId: 'commission_o1_d1' }] })],
    ['flag_amount_invalid', omitted({ parties: [{ collection: 'livreurs', id: 'd1', amountWithheld: -5, sourceJournalId: 'commission_o1_d1' }] })],
    ['flag_amount_invalid', omitted({ parties: [{ collection: 'livreurs', id: 'd1', amountWithheld: 10.5, sourceJournalId: 'commission_o1_d1' }] })],
    ['flag_currency_invalid', omitted({ currency: 'EUR' })],
    ['flag_currency_invalid', (() => { const f = omitted(); delete f.currency; return f; })()],
    ['flag_source_journal_missing', omitted({ parties: [{ collection: 'livreurs', id: 'd1', amountWithheld: 100 }] })],
    ['flag_kind_unknown', omitted({ kind: 'autre' })],
    ['flag_parties_unreadable', omitted({ parties: [] })],
    ['flag_parties_unreadable', omitted({ parties: [{ collection: 'inconnue', id: 'd1', amountWithheld: 100, sourceJournalId: 'x' }] })],
    ['flag_parties_unreadable', omitted({ parties: 'oups' })],
    ['flag_order_missing', omitted({ orderId: undefined })],
    ['flag_party_contradiction', omitted({ driverId: 'd1', clientId: 'c7' })],
    ['flag_completed_contradiction', refused({ completed: true })],
    ['flag_parties_unreadable', refused({ beneficiary: null })],
  ];
  for (const [reason, data] of cases) {
    const r = evaluate('livreur', 'd1', [doc('f1', data)]);
    const f = r.obligations.find((i) => i.source === 'reconciliation_flag');
    assert.ok(f, reason);
    assert.equal(f.state, STATE.AMBIGUOUS, reason);
    assert.equal(f.reason, reason, JSON.stringify(data).slice(0, 60));
    assert.equal(r.blocking, true, reason);
  }
});

test('bénéficiaire anonymisé : seul l’identifiant technique circule ; aucune donnée personnelle du document n’atteint le résultat', () => {
  const r = evaluate('livreur', 'd1', [doc('o1_beneficiary_closed', omitted({ parties: [{ collection: 'livreurs', id: 'd1', state: 'anonymized', reason: 'Jean Dupont 0102030405', amountWithheld: 100, sourceJournalId: 'commission_o1_d1' }], note: 'Jean Dupont' }))]);
  assert.equal(JSON.stringify(r).includes('Dupont'), false);
  assert.equal(JSON.stringify(r).includes('0102030405'), false);
});

test('SÉPARATION : statut « cleared » (verrou levé) = créance maintenue, bloquante, jamais clôturée', () => {
  for (const mk of [omitted, refused]) {
    const r = evaluate('livreur', 'd1', [doc('f1', mk({ status: 'cleared', lockLifted: true, lockLiftedBy: 'root' }))]);
    const f = flagsOf(r)[0];
    assert.equal(r.blocking, true);
    assert.equal(f.state, STATE.REVIEW);
    assert.equal(f.reason, 'flag_lock_lifted_debt_maintained');
    assert.equal(r.retained.length, 0, 'jamais classé « conservé / réglé »');
  }
});

test('clôture sans preuve : resolved / reviewed / recorded sur un signalement L4 => ambigu, bloquant (aucune décision ni preuve de règlement n’existe)', () => {
  for (const status of ['resolved', 'reviewed', 'recorded']) {
    for (const mk of [omitted, refused]) {
      const r = evaluate('livreur', 'd1', [doc('f1', mk({
        status, resolvedBy: 'root', resolvedAtMs: 5, resolutionRequestId: 'r', resolutionDecisionId: 'd', resolution: 'paid_to_partner_ledger',
        reviewedBy: 'root', reviewedAtMs: 5, requestId: 'r', decision: 'x', verification: 'refuted',
      }))]);
      const f = flagsOf(r)[0];
      assert.equal(f.state, STATE.AMBIGUOUS, status);
      assert.equal(f.reason, 'flag_closure_unproven', status);
      assert.equal(r.blocking, true, status);
      assert.equal(r.retained.length, 0, status);
    }
  }
  const r = evaluate('livreur', 'd1', [doc('f1', omitted({ status: 'bizarre' }))]);
  assert.equal(flagsOf(r)[0].reason, 'unknown_flag_status');
});

test('décision administrative sans règlement : un champ de décision ne ferme rien (statut open + decidedBy => toujours bloquant)', () => {
  const r = evaluate('livreur', 'd1', [doc('f1', omitted({ decidedBy: 'root', decision: 'pay', resolution: 'paid_to_partner_ledger' }))]);
  assert.equal(r.blocking, true);
  assert.equal(r.retained.length, 0);
});

test('rejeu / déterminisme : même entrée => même sortie ; entrée jamais modifiée', () => {
  const docs = [doc('o1_beneficiary_closed', omitted()), doc('o1_pay_beneficiary_refused', refused())];
  const frozen = JSON.parse(JSON.stringify(docs));
  const a = evaluate('livreur', 'd1', docs); const b = evaluate('livreur', 'd1', docs);
  assert.deepEqual(a, b);
  assert.deepEqual(docs, frozen);
});

test('revue de commande : les motifs L4 (beneficiary_closed, beneficiary_credit_omitted) sont nommés, jamais recopiés depuis le document', () => {
  for (const reviewReason of ['beneficiary_closed', 'beneficiary_credit_omitted', 'Jean Dupont']) {
    const r = strict({
      role: 'livreur', ids: ['d1'], terminalStatuses: TERMINAL, walletDebits: [], settlements: [], flags: [],
      orders: [{ id: 'o1', data: { status: 'cancelled', driverId: 'd1', clientId: 'c1', needsReview: true, reviewReason } }],
      reads: (() => { const req = requiredQueries('livreur', ['d1']); const reads = {}; for (const n of ['orders', 'settlements', 'flags']) reads[n] = { queries: req[n].map((q, i) => ({ ...q, limit: 201, size: i === 0 && n === 'orders' ? 1 : 0 })) }; return reads; })(),
    });
    const item = r.obligations.find((i) => i.type === TYPES.REVIEW_OPEN);
    assert.ok(item);
    assert.equal(item.reason, reviewReason === 'Jean Dupont' ? 'needs_review' : `needs_review:${reviewReason}`);
  }
});

test('erreurs de lecture : liste de signalements non fournie ou tronquée => bloquant, jamais « aucune obligation »', () => {
  const r = strict({ role: 'livreur', ids: ['d1'], terminalStatuses: TERMINAL, walletDebits: [], orders: [], settlements: [], reads: {} });
  assert.equal(r.blocking, true);
  const t = evaluate('livreur', 'd1', [doc('o1_beneficiary_closed', omitted())]);
  assert.equal(t.blocking, true);
});

// ── Écrivains réels ────────────────────────────────────────────────────────────────────────────────────────
test('flagPartyFields : champs plats additifs cohérents avec la structure imbriquée ; deux bénéficiaires du même champ => champ omis', () => {
  assert.deepEqual(flagPartyFields([{ collection: 'livreurs', id: 'd1' }, { collection: 'sellers', id: 's1' }, { collection: 'restaurants', id: 'r1' }]),
    { driverId: 'd1', sellerId: 's1', partnerId: 'r1' });
  assert.deepEqual(flagPartyFields([{ collection: 'livreurs', id: 'd1' }, { collection: 'livreurs', id: 'd2' }]), {});
  assert.deepEqual(flagPartyFields([{ collection: 'inconnue', id: 'x' }, { collection: 'livreurs', id: '' }, null]), {});
});

test('writer de refus : le signalement écrit est lu par le moteur (bénéficiaire, bloquant) — sans second schéma', async () => {
  const db = fakeDb({ 'orders/o1': { status: 'picked_up', clientId: 'c1' } });
  const admin = {};
  assert.equal(await recordBeneficiaryRefusal(db, admin, { fn: 'payOrderFromWalletCF', orderId: 'o1', details: { collection: 'livreurs', id: 'd1', cause: 'sealed' } }), true);
  const written = db.store.get('reconciliation_flags/o1_pay_beneficiary_refused');
  assert.equal(written.driverId, 'd1');
  const r = evaluate('livreur', 'd1', [doc('o1_pay_beneficiary_refused', written)]);
  assert.equal(flagsOf(r)[0].reason, 'flag_open:beneficiary_closed_refused');
  assert.equal(r.blocking, true);
  // idempotence : second refus identique => pas de réécriture
  const before = JSON.stringify(db.store.get('reconciliation_flags/o1_pay_beneficiary_refused'));
  assert.equal(await recordBeneficiaryRefusal(db, admin, { fn: 'payOrderFromWalletCF', orderId: 'o1', details: { collection: 'livreurs', id: 'd1', cause: 'sealed' } }), false);
  assert.equal(JSON.stringify(db.store.get('reconciliation_flags/o1_pay_beneficiary_refused')), before);
});

// ── Levée de verrou ≠ clôture de créance ──────────────────────────────────────────────────────────────────
const ts = (ms) => ({ toMillis: () => ms });
function billingWorld() {
  const db = fakeDb({
    'admins/root': { role: 'super', isActive: true },
    'orders/o1': { status: 'picked_up', clientId: 'c1', driverId: 'd1', needsReview: true, reviewReason: 'beneficiary_closed', reviewFlagId: 'o1_pay_beneficiary_refused' },
    'reconciliation_flags/o1_pay_beneficiary_refused': refused({ beneficiary: { collection: 'livreurs', id: 'd1', state: 'sealed' } }),
    'livreurs/d1': { wallet: 200 }, 'clients/c1': { wallet: 1000 },
  });
  const FieldValue = { serverTimestamp: () => 'ts', delete: () => ({ __delete: true }), increment: (n) => ({ __inc: n }) };
  const admin = { firestore: { FieldValue, Timestamp: { fromMillis: ts } } };
  const fn = buildAdminBilling({
    db, admin, onCall: (...a) => ({ run: a[a.length - 1] }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, requireSuperAdmin, calculateCommission,
  }).run;
  return { db, clear: (uid = 'root') => fn({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data: { action: 'clearBeneficiaryReview', orderId: 'o1', justification: 'Bénéficiaire vérifié de nouveau actif' } }) };
}

test('clearBeneficiaryReview : le verrou est levé, le signalement RESTE open (créance maintenue), le moteur le voit toujours comme bloquant', async () => {
  const w = billingWorld();
  assert.equal((await w.clear()).replay, false);
  assert.equal(w.db.store.get('orders/o1').needsReview, false);
  const fl = w.db.store.get('reconciliation_flags/o1_pay_beneficiary_refused');
  assert.equal(fl.status, 'open');
  assert.equal(fl.lockLifted, true);
  assert.equal(fl.lockLiftedBy, 'root');
  assert.equal(fl.completed, false, 'l’opération refusée n’est pas devenue « complétée »');
  assert.equal(w.db.store.get('livreurs/d1').wallet, 200, 'aucun crédit rétroactif');
  assert.equal(w.db.store.get('clients/c1').wallet, 1000);
  assert.equal([...w.db.store.keys()].some((k) => k.includes('/wallet_transactions/')), false, 'aucun journal');
  const r = evaluate('livreur', 'd1', [doc('o1_pay_beneficiary_refused', fl)]);
  assert.equal(r.blocking, true);
  assert.equal(r.retained.length, 0);
  // rejeu idempotent
  const snapshot = JSON.stringify([...w.db.store.entries()]);
  assert.equal((await w.clear()).replay, true);
  assert.equal(JSON.stringify([...w.db.store.entries()]), snapshot);
});

test('clearBeneficiaryReview : permissions (non super-admin) refusées sans écriture ; bénéficiaire toujours fermé => refus, verrou et signalement intacts', async () => {
  const w = billingWorld();
  const before = JSON.stringify([...w.db.store.entries()]);
  for (const uid of ['c1', 'd1', 'inconnu']) await assert.rejects(() => w.clear(uid));
  w.db.store.set('account_tombstones/d1', { createdAt: ts(1), state: 'deleting', phase: 'sealed', epoch: 0 });
  await assert.rejects(() => w.clear(), (e) => e.details === undefined || e.message.includes('BENEFICIARY_STILL_CLOSED'));
  w.db.store.delete('account_tombstones/d1');
  assert.equal(JSON.stringify([...w.db.store.entries()]), before);
});

test('contrat : aucune collection de décisions / preuves, aucun module exécutant, aucun statut « paid » écrit par L4.6', () => {
  const dir = path.join(__dirname, '..');
  for (const f of ['adminBilling.js', 'accountClosureActor.js']) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    assert.equal(/status:\s*'(paid|settled|resolved)'\s*,\s*(lockLifted|needsReview)/.test(src), false, f);
  }
  const ab = fs.readFileSync(path.join(dir, 'adminBilling.js'), 'utf8');
  assert.equal(/status: 'cleared'/.test(ab), false, 'plus aucun statut « cleared » écrit : levée de verrou ≠ clôture');
  assert.equal(fs.existsSync(path.join(dir, 'deferredSettlement.js')), false);
});
