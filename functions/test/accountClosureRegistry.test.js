'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const registry = require('../accountClosureRegistry');

const root = path.join(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');

// Corps d'un symbole : de sa déclaration à la prochaine déclaration de premier niveau. Approximation volontairement stricte
// pour l'ABSENCE d'une garde (tout le corps est inspecté) et suffisante pour sa PRÉSENCE.
function bodyOf(source, symbol) {
  const start = source.indexOf(`\n${symbol}`);
  assert.ok(start >= 0 || source.startsWith(symbol), `symbole introuvable : ${symbol}`);
  const from = start >= 0 ? start + 1 : 0;
  const rest = source.slice(from + symbol.length);
  const next = rest.search(/\n(?:async function |function |exports\.|module\.exports)/);
  return source.slice(from, next < 0 ? source.length : from + symbol.length + next);
}

test('structure du registre : identifiants uniques, catégories et gardes valides', () => {
  assert.deepEqual(registry.validateRegistry(), []);
  assert.ok(registry.WRITERS.length >= 40);
  assert.ok(Object.isFrozen(registry.WRITERS));
  assert.ok(registry.WRITERS.every((w) => Object.isFrozen(w) && Object.isFrozen(w.guard)));
});

test('validateRegistry détecte les erreurs : catégorie A autorisée en quarantaine, writer autorisé une fois scellé, doublons', () => {
  const base = registry.getWriter('payOrderFromWalletCF');
  assert.deepEqual(registry.validateRegistry([base, { ...base }]), [`${base.id}: identifiant dupliqué`]);
  assert.ok(registry.validateRegistry([{ ...base, id: 'x', category: 'A' }]).some((p) => /catégorie A doit refuser/.test(p)));
  assert.ok(registry.validateRegistry([{ ...base, id: 'x', sealed: 'allow' }]).some((p) => /scellé/.test(p)));
  assert.ok(registry.validateRegistry([{ ...base, id: 'x', category: 'Z' }]).some((p) => /catégorie invalide/.test(p)));
  assert.ok(registry.validateRegistry([{ ...base, id: 'x', guard: { type: 'magic' } }]).some((p) => /type de garde invalide/.test(p)));
});

test('aucun writer n’est autorisé une fois scellé ; la quarantaine suit la catégorie', () => {
  for (const w of registry.WRITERS) {
    assert.notEqual(w.sealed, 'allow', w.id);
    if (w.category === 'A') assert.equal(w.closing, 'refuse', w.id);
    if (['B', 'C', 'D'].includes(w.category)) assert.equal(w.closing, 'allow', w.id);
  }
  assert.equal(registry.getWriter('feexPayWebhook').sealed, 'hold');
  assert.equal(registry.getWriter('autoExpireOrders').sealed, 'defer');
});

test('chaque garde déclarée est RÉELLEMENT présente dans le chemin d’écriture, chaque absence est réelle', () => {
  for (const w of registry.WRITERS) {
    if (w.guard.type === 'unexamined') continue;
    const body = bodyOf(read(w.file), w.symbol);
    if (w.guard.type === 'none') {
      assert.ok(!/account_tombstones|assertNewAccountActivity|assertTargetNotClosing|assertFinancialLock/.test(body), `${w.id} : garde trouvée alors que le registre déclare « none »`);
    } else {
      assert.ok(body.includes(w.guard.token), `${w.id} : jeton ${w.guard.token} absent de ${w.file} (${w.symbol})`);
    }
  }
});

test('le registre est complet : tout fichier de production qui lit le tombstone ou appelle les gardes est couvert', () => {
  // Fichiers du moteur de suppression lui-même (ils créent ou lisent le tombstone, ce ne sont pas des writers financiers).
  const ENGINE = new Set(['accountAdmission.js', 'accountDeletion.js', 'manualAccountDeletion.js', 'partnerAccountDeletion.js',
    'accountClosureState.js', 'accountClosureLock.js', 'accountClosureRegistry.js', 'accountClosureProtocol.js', 'accountClosureActor.js']);
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
      const rel = path.posix.join(dir, entry.name);
      if (entry.isDirectory()) { if (!['node_modules', 'test', 'scripts', 'lib'].includes(entry.name)) walk(rel); }
      else if (entry.name.endsWith('.js')) files.push(rel.replace(/^\.\//, ''));
    }
  };
  walk('.');
  const covered = new Set(registry.WRITERS.map((w) => w.file));
  const uncovered = files.filter((f) => !ENGINE.has(f) && !covered.has(f))
    .filter((f) => /account_tombstones|assertNewAccountActivity|assertTargetNotClosing/.test(read(f)));
  assert.deepEqual(uncovered, [], 'fichiers lisant le tombstone sans entrée du registre');
});

test('périmètre des missions de branchement : writers de règlement sans aucune garde', () => {
  const ids = registry.unguardedSettlementWriters().map((w) => w.id).sort();
  assert.deepEqual(ids, [
    'adminApproveWithdrawalCF', 'adminBillingCF', 'adminConfirmDeliveryCF', 'adminOrderDisputeCF', 'autoExpireOrders',
    'checkPendingWithdrawals', 'ekCancelOrderCF', 'ekbineAgentDepositAction', 'partnerOrderActionCF#adminDecision', 'partnerOrderActionCF#cashRemittance',
    'refundExpiredBoutiqueOrderCF', 'settleTransferEarningsCF',
  ]);
});

test('writers non classés : aucune affirmation sur leur garde ni leur comportement ; les trois analysés en L2 sont « à confirmer »', () => {
  const unclassified = registry.listWriters({ classification: 'unclassified' });
  assert.ok(unclassified.length >= 1);
  for (const w of unclassified) {
    assert.equal(w.category, null, w.id);
    assert.equal(w.closing, 'unknown', w.id);
    assert.equal(w.sealed, 'unknown', w.id);
  }
  // Plus aucun writer « non examiné » depuis L2 ; les trois anciens sont analysés mais pas encore approuvés (D-3).
  assert.deepEqual(registry.listWriters({ guardType: 'unexamined' }).map((w) => w.id), []);
  for (const id of ['checkPendingWithdrawals', 'adminApproveWithdrawalCF', 'ekbineAgentDepositAction']) {
    assert.equal(registry.getWriter(id).guard.type, 'none', id);
    assert.equal(registry.getWriter(id).classification, 'to_confirm', id);
  }
});

test('les gardes présentes seulement dans la copie de travail non commitée sont signalées comme telles', () => {
  const local = registry.WRITERS.filter((w) => w.guard.tracking === 'working_copy').map((w) => w.id).sort();
  assert.deepEqual(local, ['adminPartnerAccounts', 'cancelOrderCF', 'confirmOrderDeliveryWithProof', 'deliverOrderCF', 'ekClientConfirmOrder', 'ekCreateOrderCF', 'ekbineAcceptOrder', 'manageProfessionalSubscription', 'payOrderFromWalletCF', 'resetAccountPassword', 'setPharmaciePassword']);
});
