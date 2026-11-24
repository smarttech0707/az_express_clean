'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { buildEkCreateOrder, buildEkCancelOrder, buildEkClientConfirmOrder, buildEkbineAcceptOrder, orderIdFor } = require('../ekbineOrders');
const { fakeDb } = require('./fakeFirestore');

const inc = (n) => ({ __inc: n });
const admin = { firestore: { FieldValue: { serverTimestamp: () => 'ts', increment: (n) => inc(n) } } };
const auth = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });
const KEY = 'key-aaaaaaaaaaaaaaaa';
const base = { idempotencyKey: KEY, operator: 'orange', serviceId: 'credit', serviceLabel: 'Crédit Orange', amount: 1000, beneficiaryNumber: '0700000000', paymentMethod: 'wallet' };

// opts : surcharge de l'interrupteur d'annulation depuis deposit_confirmed (désactivé par défaut en production).
function setup(seed = {}, opts = {}) {
  const db = fakeDb({
    'clients/c1': { wallet: 5000, name: 'Client' },
    'clients/c2': { wallet: 5000 },
    'ekbine_agents/a1': { walletBalance: 0, totalCompleted: 0, name: 'Agent', phone: '0500000000', isVerified: true, isSuspended: false, subscriptionStatus: 'active', depositAccounts: [{ id: 'orange-1', operator: 'orange', phoneNumber: '0700000001', isPrimary: true, isActive: true }] },
    'ekbine_agents/a2': { walletBalance: 0, name: 'Agent2', isVerified: true, isSuspended: false, subscriptionStatus: 'active', depositAccounts: [{ id: 'orange-2', operator: 'orange', phoneNumber: '0700000002', isPrimary: true, isActive: true }] },
    'ekbine_agents/bad': { isVerified: false, isSuspended: false, subscriptionStatus: 'active' },
    ...seed,
  });
  const audits = [];
  const deps = { db, admin, onCall: (h) => ({ run: h }), HttpsError, checkRateLimit: async () => {}, logAudit: async (a) => { audits.push(a); } };
  return { db, audits, create: buildEkCreateOrder(deps).run, cancel: buildEkCancelOrder({ ...deps, ...opts }).run, confirm: buildEkClientConfirmOrder(deps).run, accept: buildEkbineAcceptOrder(deps).run };
}
const call = (data, a = auth('c1')) => ({ auth: a, data });
const get = (h, p) => h.db.store.get(p);
const keys = (h, prefix) => [...h.db.store.keys()].filter((k) => k.startsWith(prefix));
const oid = (uid = 'c1', key = KEY) => orderIdFor(uid, key);

test('création wallet : un débit, une commande, preuve et montants calculés serveur', async () => {
  const h = setup();
  // Le client tente d'imposer frais, gain agent, statut : ignorés.
  const res = await h.create(call({ ...base, fee: 500, agentEarning: 99999, status: 'completed', totalPaid: 1 }));
  assert.equal(res.success, true);
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  const o = get(h, `ekbine_orders/${oid()}`);
  assert.deepEqual([o.fee, o.totalPaid, o.agentEarning, o.status, o.walletDebited, o.debitedAmount], [0, 1000, 1000, 'pending', true, 1000]);
  const proof = get(h, `clients/c1/wallet_transactions/ekorder_${oid()}`);
  assert.deepEqual([proof.type, proof.amount], ['payment', -1000]);
  assert.equal(h.audits.length, 1);
});

test('création : double appel même clé → un seul débit, rejeu alreadyDone', async () => {
  const h = setup();
  await h.create(call(base));
  const again = await h.create(call(base));
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal(keys(h, 'ekbine_orders/').length, 1);
});

test('création : même clé, contenu différent → refus, aucun second débit', async () => {
  const h = setup();
  await h.create(call(base));
  const res = await h.create(call({ ...base, amount: 2000 }));
  assert.equal(res.code, 'IDEMPOTENCY_CONFLICT');
  assert.equal(get(h, 'clients/c1').wallet, 4000);
});

test('création : la clé d\'un autre client ne rejoue pas sa commande', async () => {
  const h = setup();
  await h.create(call(base));
  const res = await h.create(call(base, auth('c2')));
  assert.equal(res.success, true);
  assert.notEqual(oid('c1'), oid('c2'));
  assert.equal(get(h, 'clients/c2').wallet, 4000);
});

test('création : solde insuffisant → refus, aucune commande, solde intact', async () => {
  const h = setup({ 'clients/c1': { wallet: 500 } });
  const res = await h.create(call(base));
  assert.equal(res.code, 'INSUFFICIENT_BALANCE');
  assert.equal(get(h, 'clients/c1').wallet, 500);
  assert.equal(keys(h, 'ekbine_orders/').length, 0);
});

test('création : montants/services manipulés refusés', async () => {
  const h = setup();
  for (const bad of [{ amount: 50 }, { amount: 99.5 }, { amount: -1000 }, { amount: '1000' }, { amount: 2000000 },
    { serviceId: 'inconnu' }, { operator: 'bidule' }, { paymentMethod: 'bitcoin' }, { idempotencyKey: 'court' },
    { beneficiaryNumber: '123' }, { serviceId: 'mix', operator: 'mtn' }, { amount: 150, serviceId: 'mix' }]) {
    await assert.rejects(() => h.create(call({ ...base, ...bad })), (e) => e.code === 'invalid-argument', JSON.stringify(bad));
  }
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(keys(h, 'ekbine_orders/').length, 0);
});

test('création : non connecté / anonyme / compte absent / en suppression', async () => {
  const h = setup({ 'clients/c3': { wallet: 5000, deletionRequested: true } });
  await assert.rejects(() => h.create({ data: base }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => h.create(call(base, auth('c1', 'anonymous'))), (e) => e.code === 'unauthenticated');
  assert.equal((await h.create(call(base, auth('fantome')))).code, 'ACCOUNT_NOT_FOUND');
  await assert.rejects(() => h.create(call(base, auth('c3'))), (e) => e.code === 'failed-precondition');
});

test('création hors wallet : aucune écriture de wallet, aucun gain agent prévu', async () => {
  const h = setup();
  const res = await h.create(call({ ...base, paymentMethod: 'orange_money' }));
  assert.equal(res.data.walletDebited, false);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  const o = get(h, `ekbine_orders/${oid()}`);
  assert.deepEqual([o.agentEarning, o.debitedAmount, o.walletDebited], [0, 0, false]);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/').length, 0);
});

test('annulation : remboursement du montant débité, une seule fois, statut posé', async () => {
  const h = setup();
  await h.create(call(base));
  const id = oid();
  const res = await h.cancel(call({ orderId: id, reason: 'erreur' }));
  assert.equal(res.data.refunded, 1000);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, `ekbine_orders/${id}`).status, 'cancelled');
  const again = await h.cancel(call({ orderId: id }));
  assert.equal(again.data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/ekrefund_').length, 1);
});

test('annulation : propriétaire exigé ; commande déjà exécutée refusée sans remboursement', async () => {
  const h = setup();
  await h.create(call(base));
  const id = oid();
  await assert.rejects(() => h.cancel(call({ orderId: id }, auth('c2'))), (e) => e.code === 'permission-denied');
  for (const st of ['deposit_proof_sent', 'in_progress', 'proof_sent', 'completed', 'disputed']) {
    h.db.store.set(`ekbine_orders/${id}`, { ...get(h, `ekbine_orders/${id}`), status: st });
    const res = await h.cancel(call({ orderId: id }));
    assert.equal(res.code, 'ORDER_NOT_CANCELLABLE', st);
  }
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal((await h.cancel(call({ orderId: 'absent' }))).code, 'ORDER_NOT_FOUND');
});

test('annulation : jamais remboursé sur déclaration — commande sans preuve de débit → aucun crédit + revue', async () => {
  const h = setup({ 'ekbine_orders/legacy': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', amount: 1000, totalPaid: 1000, agentEarning: 1000 } });
  const res = await h.cancel(call({ orderId: 'legacy' }));
  assert.equal(res.success, true);
  assert.equal(res.data.refunded, 0);
  assert.equal(res.data.reviewRequired, true);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, 'reconciliation_flags/ekcancel_legacy').status, 'open');
});

test('annulation : commande hors wallet → aucun remboursement', async () => {
  const h = setup();
  await h.create(call({ ...base, paymentMethod: 'wave' }));
  const res = await h.cancel(call({ orderId: oid() }));
  assert.equal(res.data.refunded, 0);
  assert.equal(res.data.reviewRequired, false);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
});

const ready = (extra = {}) => ({
  clientId: 'c1', agentId: 'a1', status: 'proof_sent', paymentMethod: 'wallet', amount: 1000,
  walletDebited: true, debitedAmount: 1000, agentEarning: 1000, ...extra,
});

test('confirmation : crédite le montant PROUVÉ, une seule fois', async () => {
  const h = setup({ 'ekbine_orders/o1': ready({ agentEarning: 999999 }) });
  const res = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(res.credited, 1000);
  assert.equal(res.settlement, 'wallet_credit');
  assert.deepEqual(get(h, 'ekbine_agents/a1').walletBalance, inc(1000));
  assert.equal(get(h, 'ekbine_orders/o1').status, 'completed');
  const again = await h.confirm(call({ orderId: 'o1' }));
  assert.equal(again.alreadyDone, true);
  await assert.rejects(() => Promise.resolve(h.confirm(call({ orderId: 'o1' }, auth('c2')))), (e) => e.code === 'permission-denied');
});

test('confirmation : agentEarning manipulé, sans preuve de débit → aucun crédit agent + signalement', async () => {
  const h = setup({ 'ekbine_orders/o2': ready({ walletDebited: undefined, debitedAmount: undefined, agentEarning: 50000 }) });
  const res = await h.confirm(call({ orderId: 'o2' }));
  assert.equal(res.credited, 0);
  assert.equal(res.reviewRequired, true);
  assert.equal(res.settlement, 'withheld_unproven');
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
  assert.equal(get(h, 'reconciliation_flags/ekconfirm_o2').status, 'open');
});

test('confirmation : montant débité différent du montant commande ou commande remboursée → aucun crédit', async () => {
  const h = setup({
    'ekbine_orders/o3': ready({ debitedAmount: 100 }),
    'ekbine_orders/o4': ready({ refunded: true }),
  });
  assert.equal((await h.confirm(call({ orderId: 'o3' }))).credited, 0);
  assert.equal((await h.confirm(call({ orderId: 'o4' }))).credited, 0);
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
});

test('confirmation hors wallet : terminée sans aucun crédit (AZ ne détient pas les fonds)', async () => {
  const h = setup({ 'ekbine_orders/o5': ready({ paymentMethod: 'orange_money', agentEarning: 0, walletDebited: false, debitedAmount: 0 }) });
  const res = await h.confirm(call({ orderId: 'o5' }));
  assert.equal(res.success, true);
  assert.equal(res.credited, 0);
  assert.equal(res.reviewRequired, false);
  assert.equal(res.settlement, 'declarative_no_credit');
  assert.equal(get(h, 'ekbine_orders/o5').creditReason, 'non_wallet');
  assert.equal(get(h, 'ekbine_orders/o5').status, 'completed');
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/').length, 0);
});

test('confirmation : annulée ou mauvais statut refusée', async () => {
  const h = setup({ 'ekbine_orders/o6': ready({ status: 'cancelled' }), 'ekbine_orders/o7': ready({ status: 'in_progress' }) });
  for (const id of ['o6', 'o7']) {
    await assert.rejects(() => Promise.resolve(h.confirm(call({ orderId: id }))), (e) => e.code === 'failed-precondition');
  }
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0);
});

// ── Acceptation (parcours wallet) et annulation avant exécution ─────────────
const accept = (h, orderId, uid = 'a1') => h.accept({ auth: auth(uid), data: { orderId } });
const ledgerCount = (h) => keys(h, 'clients/c1/wallet_transactions/').length;

test('acceptation wallet à débit prouvé : directement deposit_confirmed, aucun dépôt demandé, aucun mouvement d\'argent', async () => {
  const h = setup();
  await h.create(call(base));
  const id = oid();
  const ledgerBefore = ledgerCount(h);
  const res = await accept(h, id);
  assert.equal(res.status, 'deposit_confirmed');
  const o = get(h, `ekbine_orders/${id}`);
  assert.deepEqual([o.status, o.agentId, o.agentName, o.agentPhone], ['deposit_confirmed', 'a1', 'Agent', '0500000000']);
  assert.equal(o.agentDepositNumber, undefined, 'aucune consigne de dépôt pour un client déjà débité');
  assert.equal(get(h, 'clients/c1').wallet, 4000, 'aucun second débit');
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0, 'aucun crédit agent à l\'acceptation');
  assert.equal(ledgerCount(h), ledgerBefore);
});

test('acceptation hors wallet : parcours de dépôt inchangé (awaiting_deposit + numéro de l\'agent)', async () => {
  const h = setup();
  await h.create(call({ ...base, paymentMethod: 'orange_money' }));
  const res = await accept(h, oid());
  assert.equal(res.status, 'awaiting_deposit');
  const o = get(h, `ekbine_orders/${oid()}`);
  assert.deepEqual([o.agentDepositNumber, o.agentDepositOperator, o.agentDepositAccountId], ['0700000001', 'orange', 'orange-1']);
});

test('acceptation : commande wallet SANS preuve (historique) ou preuve incohérente → aucun contournement du dépôt', async () => {
  const h = setup({
    'ekbine_orders/legacy': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', operator: 'orange', amount: 1000, agentEarning: 1000 },
    'ekbine_orders/mism': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', operator: 'orange', amount: 1000, walletDebited: true, debitedAmount: 10 },
    'ekbine_orders/forged': { clientId: 'c1', status: 'pending', paymentMethod: 'wallet', operator: 'orange', amount: 1000, walletDebited: true, debitedAmount: 1000, refunded: true },
  });
  for (const id of ['legacy', 'mism', 'forged']) {
    assert.equal((await accept(h, id)).status, 'awaiting_deposit', id);
  }
});

test('double acceptation : seul le premier agent est affecté, le second est refusé', async () => {
  const h = setup();
  await h.create(call(base));
  await accept(h, oid(), 'a1');
  await assert.rejects(() => accept(h, oid(), 'a2'), (e) => e.code === 'failed-precondition');
  await assert.rejects(() => accept(h, oid(), 'a1'), (e) => e.code === 'failed-precondition');
  assert.equal(get(h, `ekbine_orders/${oid()}`).agentId, 'a1');
});

test('acceptation : agent non éligible, inconnu, non connecté refusés', async () => {
  const h = setup();
  await h.create(call(base));
  await assert.rejects(() => accept(h, oid(), 'bad'), (e) => e.code === 'permission-denied');
  await assert.rejects(() => accept(h, oid(), 'inconnu'), (e) => e.code === 'permission-denied');
  await assert.rejects(() => h.accept({ data: { orderId: oid() } }), (e) => e.code === 'unauthenticated');
  assert.equal(get(h, `ekbine_orders/${oid()}`).status, 'pending');
});

test('annulation depuis deposit_confirmed (débit prouvé, opération non commencée) : remboursement unique', async () => {
  const h = setup({}, { allowCancelFromDepositConfirmed: true });
  await h.create(call(base));
  await accept(h, oid());
  const res = await h.cancel(call({ orderId: oid() }));
  assert.equal(res.success, true);
  assert.equal(res.data.refunded, 1000);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, `ekbine_orders/${oid()}`).status, 'cancelled');
  assert.equal((await h.cancel(call({ orderId: oid() }))).data.alreadyDone, true);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/ekrefund_').length, 1);
  assert.equal(get(h, 'ekbine_agents/a1').walletBalance, 0, 'l\'agent n\'est jamais crédité d\'une commande annulée');
});

test('annulation refusée dès que l\'exécution a commencé ou abouti (aucun remboursement après opération exécutée)', async () => {
  const h = setup({}, { allowCancelFromDepositConfirmed: true });
  await h.create(call(base));
  await accept(h, oid());
  const path = `ekbine_orders/${oid()}`;
  const original = get(h, path);
  for (const patch of [{ status: 'in_progress' }, { startedAt: 'ts' }, { proofUrl: 'u' }, { agentCredited: 0 }, { completedAt: 'ts' },
    { status: 'proof_sent', startedAt: 'ts', proofUrl: 'u' }, { status: 'completed', startedAt: 'ts' }]) {
    h.db.store.set(path, { ...original, ...patch });
    const res = await h.cancel(call({ orderId: oid() }));
    assert.equal(res.code, 'ORDER_NOT_CANCELLABLE', JSON.stringify(patch));
  }
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal(keys(h, 'clients/c1/wallet_transactions/ekrefund_').length, 0);
});

test('annulation depuis deposit_confirmed refusée : commande hors wallet, sans preuve, ou déjà remboursée', async () => {
  const h = setup({
    'ekbine_orders/nw': { clientId: 'c1', status: 'deposit_confirmed', paymentMethod: 'orange_money', amount: 1000 },
    'ekbine_orders/legacy': { clientId: 'c1', status: 'deposit_confirmed', paymentMethod: 'wallet', amount: 1000 },
    'ekbine_orders/rf': { clientId: 'c1', status: 'deposit_confirmed', paymentMethod: 'wallet', amount: 1000, walletDebited: true, debitedAmount: 1000, refunded: true, refundedAmount: 1000 },
  }, { allowCancelFromDepositConfirmed: true });
  for (const id of ['nw', 'legacy', 'rf']) {
    assert.equal((await h.cancel(call({ orderId: id }))).code, 'ORDER_NOT_CANCELLABLE', id);
  }
  assert.equal(get(h, 'clients/c1').wallet, 5000);
});

test('parcours complet : création → acceptation → exécution → confirmation ; annulation ensuite refusée, un seul crédit', async () => {
  const h = setup();
  await h.create(call(base));
  const path = `ekbine_orders/${oid()}`;
  await accept(h, oid());
  h.db.store.set(path, { ...get(h, path), status: 'proof_sent', startedAt: 'ts', proofUrl: 'u' });
  const c = await h.confirm(call({ orderId: oid() }));
  assert.equal(c.settlement, 'wallet_credit');
  assert.equal((await h.cancel(call({ orderId: oid() }))).code, 'ORDER_NOT_CANCELLABLE');
  assert.deepEqual(get(h, 'ekbine_agents/a1').walletBalance, inc(1000));
  assert.equal(get(h, 'clients/c1').wallet, 4000);
});

// ── Interrupteur EK_CANCEL_FROM_DEPOSIT_CONFIRMED (désactivé par défaut) ────
test('interrupteur désactivé par défaut : annulation refusée depuis deposit_confirmed, aucun remboursement', async () => {
  delete process.env.EK_CANCEL_FROM_DEPOSIT_CONFIRMED;
  const h = setup();
  await h.create(call(base));
  await accept(h, oid());
  const res = await h.cancel(call({ orderId: oid() }));
  assert.equal(res.code, 'ORDER_NOT_CANCELLABLE');
  assert.equal(get(h, 'clients/c1').wallet, 4000);
  assert.equal(get(h, `ekbine_orders/${oid()}`).status, 'deposit_confirmed');
  assert.equal(keys(h, 'clients/c1/wallet_transactions/ekrefund_').length, 0);
});

test('interrupteur désactivé : l\'annulation AVANT acceptation (pending) continue de rembourser', async () => {
  delete process.env.EK_CANCEL_FROM_DEPOSIT_CONFIRMED;
  const h = setup();
  await h.create(call(base));
  const res = await h.cancel(call({ orderId: oid() }));
  assert.equal(res.data.refunded, 1000);
  assert.equal(get(h, 'clients/c1').wallet, 5000);
  assert.equal(get(h, `ekbine_orders/${oid()}`).status, 'cancelled');
});

test('interrupteur : seule la valeur exacte "true" de l\'environnement l\'active, lue à chaque appel', async () => {
  const h = setup();
  await h.create(call(base));
  await accept(h, oid());
  try {
    for (const v of ['1', 'TRUE', 'yes', '', 'false']) {
      process.env.EK_CANCEL_FROM_DEPOSIT_CONFIRMED = v;
      assert.equal((await h.cancel(call({ orderId: oid() }))).code, 'ORDER_NOT_CANCELLABLE', v);
    }
    process.env.EK_CANCEL_FROM_DEPOSIT_CONFIRMED = 'true';
    const res = await h.cancel(call({ orderId: oid() }));
    assert.equal(res.data.refunded, 1000);
    assert.equal(get(h, 'clients/c1').wallet, 5000);
  } finally {
    delete process.env.EK_CANCEL_FROM_DEPOSIT_CONFIRMED;
  }
});
