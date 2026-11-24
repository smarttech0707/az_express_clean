'use strict';

// L2.2 — branchement du prédicat de retraits (accountObligations.classifyWithdrawal) dans les chemins réels de suppression :
// client/livreur (accountDeletion.inspect), partenaire (accountDeletionScope.readDeletionScope). Faux Firestore en mémoire, aucun cloud.
// Un compte qui n'a que des retraits réglés n'est plus bloqué à tort ; toute obligation ouverte, ambiguë ou non lue bloque.
const test = require('node:test');
const assert = require('node:assert/strict');
const { makeWorld, UID } = require('./support/closureWorld');

const wd = (over = {}) => ({ userId: UID, userType: 'client', amount: 2000, provider: 'FeexPay', ...over });
const SETTLED = { status: 'sent', settlementConfirmed: true, needsReview: false };
const MANUAL = { status: 'processed', settlementConfirmed: true, processedBy: 'adm1' };
const REFUNDED = { status: 'failed_refunded', compensated: true, settlementConfirmed: false };

const CASES = [
  // [libellé, documents de retrait, bloque ?, motif attendu]
  ['sent confirmé', [wd(SETTLED)], false],
  ['processed confirmé', [wd(MANUAL)], false],
  ['failed_refunded compensé', [wd(REFUNDED)], false],
  ['plusieurs retraits tous réglés', [wd(SETTLED), wd(MANUAL), wd(REFUNDED)], false],
  ['sent sans preuve d’exécution', [wd({ status: 'sent' })], true, 'financial_regularization_required'],
  ['sent avec settlementConfirmed:false', [wd({ status: 'sent', settlementConfirmed: false })], true, 'financial_regularization_required'],
  ['processed sans preuve', [wd({ status: 'processed' })], true, 'financial_regularization_required'],
  ['processed sans processedBy', [wd({ status: 'processed', settlementConfirmed: true })], true, 'financial_regularization_required'],
  ['failed_refunded sans preuve de compensation', [wd({ status: 'failed_refunded' })], true, 'financial_regularization_required'],
  ['processing', [wd({ status: 'processing' })], true, 'active_or_unresolved_operation'],
  ['provider_pending', [wd({ status: 'provider_pending' })], true, 'active_or_unresolved_operation'],
  ['pending_manual', [wd({ status: 'pending_manual' })], true, 'active_or_unresolved_operation'],
  ['un réglé + un en attente', [wd(SETTLED), wd({ status: 'processing' })], true, 'active_or_unresolved_operation'],
  ['un réglé + un sans preuve', [wd(SETTLED), wd({ status: 'sent' })], true, 'financial_regularization_required'],
  ['statut inconnu', [wd({ status: 'weird' })], true, 'financial_regularization_required'],
  ['ancien statut pending', [wd({ status: 'pending' })], true, 'financial_regularization_required'],
  ['statut absent', [wd({ status: undefined })], true, 'financial_regularization_required'],
  ['montant absent (données incomplètes)', [wd({ ...SETTLED, amount: undefined })], true, 'financial_regularization_required'],
  ['drapeaux contradictoires', [wd({ status: 'sent', settlementConfirmed: true, compensated: true })], true, 'financial_regularization_required'],
  ['needsReview sur un retrait réglé', [wd({ ...SETTLED, needsReview: true })], true, 'financial_regularization_required'],
  ['remboursement en attente conservé bloquant', [wd({ ...SETTLED, refundPending: true })], true, 'financial_regularization_required'],
];
const seedOf = (docs) => Object.fromEntries(docs.map((d, i) => [`withdrawal_requests/w${i}`, d]));

// ── Chemin client ───────────────────────────────────────────────────────────────────────────────────────────────────
for (const [label, docs, blocks, reason] of CASES) {
  test(`client : ${label} -> ${blocks ? 'bloque' : 'ne bloque pas'}`, async () => {
    const w = makeWorld({ seed: seedOf(docs) });
    await w.quarantine();
    const out = await w.afterQuiet();
    if (blocks) {
      assert.notEqual(w.job().state, 'completed');
      assert.equal(w.job().reason, reason);
      assert.ok(!w.state.calls.includes('delete'), 'aucune suppression Auth');
      // Refus dès la quarantaine (aucun tombstone) ou, à défaut, tombstone jamais scellé.
      assert.notEqual(w.tomb() && w.tomb().phase, 'sealed', 'jamais scellé');
    } else {
      assert.equal(out.status, 'completed');
      assert.equal(w.job().state, 'completed');
      assert.equal(w.tomb().phase, 'sealed');
    }
  });
}

test('livreur : retrait sent confirmé ne bloque pas, retrait en cours bloque', async () => {
  const ok = makeWorld({ role: 'livreur', seed: seedOf([wd({ ...SETTLED, userType: 'livreur' })]) });
  await ok.quarantine();
  assert.equal((await ok.afterQuiet()).status, 'completed');
  const ko = makeWorld({ role: 'livreur', seed: seedOf([wd({ status: 'processing', userType: 'livreur' })]) });
  await ko.quarantine();
  await ko.afterQuiet();
  assert.equal(ko.job().reason, 'active_or_unresolved_operation');
});

test('client : les retraits réglés restent dans l’historique anonymisé (comme avant)', async () => {
  const w = makeWorld({ seed: seedOf([wd({ ...SETTLED, name: 'Awa', phone: '0700000000' })]) });
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.db.store.get('withdrawal_requests/w0').status, 'sent', 'le retrait n’est pas supprimé');
});

test('client : un retrait d’un autre compte n’est pas pris en compte', async () => {
  const w = makeWorld({ seed: seedOf([wd({ status: 'processing', userId: 'someone-else' })]) });
  await w.quarantine();
  assert.equal((await w.afterQuiet()).status, 'completed');
});

test('client : plafond de lecture — 201 retraits = revue manuelle (pas de liste tronquée)', async () => {
  const docs = Array.from({ length: 201 }, (_, i) => [`withdrawal_requests/w${i}`, wd(SETTLED)]);
  const w = makeWorld({ seed: Object.fromEntries(docs) });
  await w.quarantine();
  await w.afterQuiet();
  assert.equal(w.job().reason, 'history_requires_manual_review');
  assert.ok(!w.state.calls.includes('delete'));
});

test('client : erreur de lecture des retraits = échec, jamais une liste vide (aucune suppression, aucun scellé)', async () => {
  const w = makeWorld({ seed: seedOf([wd(SETTLED)]) });
  await w.quarantine();
  w.db.store.queryFailure = (name) => name === 'withdrawal_requests';
  await assert.rejects(w.afterQuiet(), /read failure withdrawal_requests/);
  assert.ok(!w.state.calls.includes('delete'));
  assert.equal(w.tomb().phase, 'closing');
  assert.notEqual(w.job().state, 'completed');
});

// ── Chemin partenaire ───────────────────────────────────────────────────────────────────────────────────────────────
for (const [label, docs, blocks, reason] of CASES) {
  test(`partenaire : ${label} -> ${blocks ? 'bloque' : 'ne bloque pas'}`, async () => {
    const w = makeWorld({ role: 'seller', partner: true, seed: seedOf(docs.map((d) => ({ ...d, userType: 'seller' }))) });
    await w.quarantine();
    if (blocks) {
      // Le périmètre refuse dès la demande ou à l'échéance : dans les deux cas, ni scellé ni suppression Auth.
      await w.afterQuiet();
      assert.notEqual(w.job().state, 'completed');
      assert.equal(w.job().reason, reason);
      assert.ok(!w.state.calls.includes('delete'));
      assert.notEqual(w.tomb() && w.tomb().phase, 'sealed');
    } else {
      await w.afterQuiet();
      assert.equal(w.job().state, 'completed');
      assert.equal(w.tomb().phase, 'sealed');
    }
  });
}

test('partenaire : erreur de lecture des retraits = échec, aucune suppression', async () => {
  const w = makeWorld({ role: 'seller', partner: true, seed: seedOf([wd(SETTLED)]) });
  await w.quarantine();
  w.db.store.queryFailure = (name) => name === 'withdrawal_requests';
  await assert.rejects(w.afterQuiet(), /read failure withdrawal_requests/);
  assert.ok(!w.state.calls.includes('delete'));
  assert.notEqual(w.job().state, 'completed');
});
