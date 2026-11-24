'use strict';

// L4.5 — chemins administratifs financiers (resolveFeeHold, closeStuckDelivery, refundBoutiqueOrder, adminOrderDisputes
// exceptionalCancel / partialRefund, transferSettlement.approve) : tous les bénéficiaires crédités (ou débités) sont vérifiés dans la
// transaction AVANT toute écriture ; un seul fermé, absent ou illisible => refus de toute l'opération, aucun crédit partiel, aucun
// journal fictif, aucune retenue marquée résolue. Fonctions réelles sur faux Firestore ; données fictives.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildAdminBilling } = require('../adminBilling');
const { buildAdminOrderDispute } = require('../adminOrderDisputes');
const { buildSettleTransferEarnings } = require('../transferSettlement');
const { requireAdminPermission, requireSuperAdmin } = require('../adminGuards');
const { calculateCommission } = require('../dispatch');
const { buildProposal, settlementDocument } = require('../earningsSettlement');

void buildProposal;
const ts = (ms) => ({ toMillis: () => ms });
const T = Date.parse('2026-07-01T00:00:00Z');
const admin = {
  firestore: {
    Timestamp: { fromMillis: ts },
    FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion, increment: (n) => ({ __increment: n }) },
  },
};
const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
const J = 'Décision administrative vérifiée avec le client';
const closed = (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED';
// Profil absent : certains chemins refusent AVANT la garde avec leur message historique « introuvable » ; refus dans tous les cas.
const refused = (e) => closed(e) || (e.code === 'failed-precondition' && /introuvable/.test(e.message));
const tomb = (over = {}) => ({ createdAt: ts(T + 1000), state: 'deleting', ...over });

const arrange = {
  active: () => {},
  quarantine: (db, col, id) => db.store.set(`account_tombstones/${id}`, tomb()),
  sealed: (db, col, id) => db.store.set(`account_tombstones/${id}`, tomb({ phase: 'sealed' })),
  anonymized: (db, col, id) => db.store.set(`${col}/${id}`, { ...(db.store.get(`${col}/${id}`) || {}), isDeleted: true }),
  absent: (db, col, id) => db.store.delete(`${col}/${id}`),
  unreadable: (db, col, id) => db.store.set(`account_tombstones/${id}`, tomb({ phase: 'bogus' })),
};
const STATES = Object.keys(arrange);
const snap = (db) => JSON.stringify([...db.store.entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
const journals = (db) => [...db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));

const failingGet = (tx, re) => new Proxy(tx, {
  get: (t, k) => (k === 'get' ? async (ref) => { if (re.test(ref.path || '')) throw new Error('boom'); return t.get(ref); } : (typeof t[k] === 'function' ? t[k].bind(t) : t[k])),
});

function mk(seed) {
  const db = fakeDb({ 'admins/root': { role: 'super', isActive: true }, 'admins/sub': { role: 'sub', isActive: true, permissions: ['commandes'] }, ...seed });
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {} };
  const billing = buildAdminBilling({ ...common, onCall: oc, calculateCommission, requireSuperAdmin }).run;
  const disputes = buildAdminOrderDispute({ ...common, onCall: oc, requireAdminPermission, requireSuperAdmin, calculateCommission }).run;
  const settle = buildSettleTransferEarnings({ ...common, onCall: oc, requireSuperAdmin }).run;
  return {
    db,
    billing: (data, uid = 'root') => billing({ auth: authOf(uid), data: { orderId: 'o1', justification: J, ...data } }),
    dispute: (data, uid = 'root') => disputes({ auth: authOf(uid), data: { orderId: 'o1', justification: J, requestId: 'request-id-000000001', ...data } }),
    settle: (data, uid = 'root') => settle({ auth: authOf(uid), data: { orderId: 'o1', ...data } }),
  };
}

// Joue un scénario sur le produit cartésien d'états des bénéficiaires. targets = [{ col, id }].
async function matrix(label, build, targets, op, okCheck) {
  const combos = targets.length === 1 ? STATES.map((s) => [s]) : STATES.flatMap((a) => STATES.map((b) => [a, b]));
  for (const states of combos) {
    const w = build();
    states.forEach((s, i) => arrange[s](w.db, targets[i].col, targets[i].id));
    const name = `${label} [${states.join('/')}]`;
    if (states.every((s) => s === 'active')) {
      await op(w);
      okCheck(w, name);
      const keys = journals(w.db).sort();
      try { await op(w); } catch (_) { /* rejeu refusé : accepté */ }
      assert.deepEqual(journals(w.db).sort(), keys, `${name} : rejeu sans second journal`);
    } else {
      const before = snap(w.db);
      for (let i = 0; i < 2; i += 1) {
        await assert.rejects(() => op(w), states.includes('absent') ? refused : closed, name);
        assert.equal(snap(w.db), before, `${name} : rien n'a bougé (essai ${i + 1})`);
      }
    }
  }
}

// ------------------------------------------------------------------ resolveFeeHold
const holdSeed = (extra = {}) => () => mk({
  'orders/o1': {
    clientId: 'c1', driverId: 'dA', status: 'cancelled', sellerType: 'seller', paymentMethod: 'wallet',
    deliveryFeeHold: { amount: 500, status: 'pending_admin_review', driverId: 'dA' },
    commissionStatus: 'charged', commissionPayerId: 'dP', commissionAmount: 100, ...extra,
  },
  'clients/c1': { wallet: 1000 }, 'livreurs/dA': { wallet: 900 }, 'livreurs/dP': { wallet: 400 },
});

test('resolveFeeHold refundClient : client × payeur de commission (36 combinaisons) — aucun crédit partiel, retenue non résolue', async () => {
  await matrix('refundClient', holdSeed(), [{ col: 'clients', id: 'c1' }, { col: 'livreurs', id: 'dP' }],
    (w) => w.billing({ action: 'resolveFeeHold', decision: 'refundClient' }),
    (w, n) => {
      assert.equal(w.db.store.get('clients/c1').wallet, 1500, n);
      assert.equal(w.db.store.get('livreurs/dP').wallet, 500, n);
      assert.equal(w.db.store.get('orders/o1').deliveryFeeHold.status, 'resolved', n);
    });
});

test('resolveFeeHold payDriver : livreur de la retenue (6 états) — aucun détournement vers AZ, commissions inchangées', async () => {
  await matrix('payDriver', holdSeed(), [{ col: 'livreurs', id: 'dA' }],
    (w) => w.billing({ action: 'resolveFeeHold', decision: 'payDriver' }),
    (w, n) => { assert.equal(w.db.store.get('livreurs/dA').wallet, 1400, n); });
  const w = holdSeed()(); arrange.sealed(w.db, 'livreurs', 'dA');
  await assert.rejects(() => w.billing({ action: 'resolveFeeHold', decision: 'payDriver' }), closed);
  assert.equal(w.db.store.get('config/az_wallet'), undefined);
  assert.equal(w.db.store.get('orders/o1').deliveryFeeHold.status, 'pending_admin_review');
});

test('resolveFeeHold retain : payeur de commission fermé => refus (commission à rendre) ; sans commission tracée, retenue AZ sans bénéficiaire', async () => {
  const w = holdSeed()(); arrange.absent(w.db, 'livreurs', 'dP');
  await assert.rejects(() => w.billing({ action: 'resolveFeeHold', decision: 'retain' }), closed);
  assert.equal(w.db.store.get('orders/o1').deliveryFeeHold.status, 'pending_admin_review');
  assert.equal(w.db.store.get('config/az_wallet'), undefined);
  const n = holdSeed({ commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined })();
  arrange.sealed(n.db, 'clients', 'c1');
  await n.billing({ action: 'resolveFeeHold', decision: 'retain' });
  assert.equal(n.db.store.get('orders/o1').deliveryFeeHold.status, 'resolved');
});

test('resolveFeeHold : erreur de lecture Firestore => refus sans écriture ; permissions ; retry après régularisation = un seul crédit', async () => {
  const w = holdSeed()();
  const orig = w.db.runTransaction;
  w.db.runTransaction = (cb) => orig((tx) => cb(failingGet(tx, new RegExp('account_tombstones/c1$'))));
  const before = snap(w.db);
  await assert.rejects(() => w.billing({ action: 'resolveFeeHold', decision: 'refundClient' }), /boom/);
  assert.equal(snap(w.db), before);
  w.db.runTransaction = orig;
  for (const uid of ['sub', 'c1', 'dA', 'inconnu']) {
    await assert.rejects(() => w.billing({ action: 'resolveFeeHold', decision: 'refundClient' }, uid));
  }
  assert.equal(snap(w.db), before);
  arrange.quarantine(w.db, 'clients', 'c1');
  await assert.rejects(() => w.billing({ action: 'resolveFeeHold', decision: 'refundClient' }), closed);
  w.db.store.delete('account_tombstones/c1'); // simulation de test : compte réellement actif (un tombstone réel n'est jamais supprimé)
  await w.billing({ action: 'resolveFeeHold', decision: 'refundClient' });
  await w.billing({ action: 'resolveFeeHold', decision: 'refundClient' });
  assert.equal(w.db.store.get('clients/c1').wallet, 1500);
  assert.equal(journals(w.db).filter((k) => k.startsWith('clients/c1/')).length, 1);
});

// ------------------------------------------------------------------ refundBoutiqueOrder
const boutiqueSeed = () => mk({
  'boutique_orders/o1': { clientId: 'c1', sellerId: 's1', status: 'paid', paymentMethod: 'wallet', totalPrice: 5000 },
  'clients/c1': { wallet: 1000 }, 'sellers/s1': { wallet: 8000 },
});

test('refundBoutiqueOrder : client × vendeur (36 combinaisons) — ni remboursement, ni débit vendeur, ni statut « refunded »', async () => {
  await matrix('refundBoutique', boutiqueSeed, [{ col: 'clients', id: 'c1' }, { col: 'sellers', id: 's1' }],
    (w) => w.billing({ action: 'refundBoutiqueOrder' }),
    (w, n) => {
      assert.equal(w.db.store.get('clients/c1').wallet, 6000, n);
      assert.equal(w.db.store.get('sellers/s1').wallet, 3000, n);
      assert.equal(w.db.store.get('boutique_orders/o1').status, 'refunded', n);
    });
});

test('refundBoutiqueOrder : permissions et erreur de lecture', async () => {
  const w = boutiqueSeed(); const before = snap(w.db);
  for (const uid of ['sub', 'c1', 's1']) await assert.rejects(() => w.billing({ action: 'refundBoutiqueOrder' }, uid));
  assert.equal(snap(w.db), before);
  const orig = w.db.runTransaction;
  w.db.runTransaction = (cb) => orig((tx) => cb(failingGet(tx, new RegExp('account_tombstones/s1$'))));
  await assert.rejects(() => w.billing({ action: 'refundBoutiqueOrder' }), /boom/);
  assert.equal(snap(w.db), before);
});

// ------------------------------------------------------------------ closeStuckDelivery (cancelOrderTx, mode administratif)
const stuckSeed = () => mk({
  'orders/o1': {
    clientId: 'c1', driverId: 'dA', status: 'accepted', type: 'marketplace', sellerType: 'seller', sellerId: 's1',
    paymentMethod: 'wallet', isPaid: true, amountsVersion: 1, productAmount: 4500, deliveryFee: 500, totalAmount: 5000, budget: 500,
    shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100, acceptedAt: ts(T), createdAt: ts(T),
  },
  'clients/c1': { wallet: 1000 }, 'sellers/s1': { wallet: 8000 }, 'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1' },
});

test('closeStuckDelivery : client, vendeur (débit) et payeur de commission — chacun fermé => refus intégral, aucun crédit ni débit partiel', async () => {
  const targets = [{ col: 'clients', id: 'c1' }, { col: 'sellers', id: 's1' }];
  await matrix('closeStuck', stuckSeed, targets,
    (w) => w.billing({ action: 'closeStuckDelivery', refundFee: true }),
    (w, n) => { assert.equal(w.db.store.get('orders/o1').status, 'cancelled', n); assert.ok(w.db.store.get('clients/c1').wallet > 1000, n); });
  for (const s of STATES.filter((x) => x !== 'active')) {
    const w = stuckSeed(); arrange[s](w.db, 'livreurs', 'dA');
    const before = snap(w.db);
    await assert.rejects(() => w.billing({ action: 'closeStuckDelivery', refundFee: true }), closed, `payeur ${s}`);
    assert.equal(snap(w.db), before, `payeur ${s} : rien n'a bougé`);
  }
});

// ------------------------------------------------------------------ adminOrderDisputes
const disputeSeed = (extra = {}) => () => mk({
  'orders/o1': {
    clientId: 'c1', driverId: 'dA', status: 'picked_up', type: 'livraison', paymentMethod: 'wallet', isPaid: true, budget: 1000,
    shoppingBudget: 2000, pickedUpAt: 1, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
    cancelRequestAfterPickup: { status: 'pending_admin_review', requestedBy: 'c1', requestedAtMs: 5 }, ...extra,
  },
  'clients/c1': { wallet: 7000 }, 'livreurs/dA': { wallet: 800 },
});

test('adminOrderDisputes exceptionalCancel : client × livreur (payeur de commission) — 36 combinaisons', async () => {
  await matrix('exceptionalCancel', disputeSeed(), [{ col: 'clients', id: 'c1' }, { col: 'livreurs', id: 'dA' }],
    (w) => w.dispute({ action: 'decide', decision: 'exceptionalCancel', shoppingContext: 'not_purchased' }),
    (w, n) => { assert.equal(w.db.store.get('orders/o1').status, 'cancelled', n); });
});

test('adminOrderDisputes partialRefund : client × livreur (36 combinaisons) — aucune décision enregistrée sur refus', async () => {
  await matrix('partialRefund', disputeSeed(), [{ col: 'clients', id: 'c1' }, { col: 'livreurs', id: 'dA' }],
    (w) => w.dispute({ action: 'decide', decision: 'refundHalfFee', shoppingContext: 'not_purchased' }),
    (w, n) => { assert.equal(w.db.store.get('orders/o1').status, 'delivered', n); });
  const w = disputeSeed()(); arrange.sealed(w.db, 'livreurs', 'dA');
  await assert.rejects(() => w.dispute({ action: 'decide', decision: 'refundHalfFee', shoppingContext: 'not_purchased' }), closed);
  assert.ok(![...w.db.store.keys()].some((k) => k.startsWith('order_dispute_decisions/')));
});

test('adminOrderDisputes : permissions (sous-admin sans droit, client, livreur) refusées sans écriture', async () => {
  const w = disputeSeed()(); const before = snap(w.db);
  for (const uid of ['sub', 'c1', 'dA']) {
    await assert.rejects(() => w.dispute({ action: 'decide', decision: 'exceptionalCancel', shoppingContext: 'not_purchased' }, uid));
  }
  assert.equal(snap(w.db), before);
});

// ------------------------------------------------------------------ transferSettlement.approve
const settleSeed = () => {
  const order = {
    clientId: 'c1', status: 'delivered', driverId: 'dB', budget: 1000, settlementHold: true, latitude: 6.70, longitude: -3.49,
    destLat: 6.80, destLng: -3.49, pickedUpAt: 1, deliveryPhoto: 'p.jpg', commissionStatus: 'charged', commissionPayerId: 'dA',
    commissionAmount: 200,
    driverHistory: [{ driverId: 'dA', phase: 'after_pickup', transferId: 't1', endedAtMs: 10, handover: { trusted: true, point: { lat: 6.74, lng: -3.49 } } }],
  };
  return mk({
    'orders/o1': order, 'transfer_settlements/o1': settlementDocument('o1', order, 'wallet', 1000),
    'livreurs/dA': { wallet: 300 }, 'livreurs/dB': { wallet: 0 },
  });
};

test('transferSettlement approve (wallet) : deux livreurs (36 combinaisons) — aucun crédit partiel, jamais « settled », retenue conservée', async () => {
  await matrix('settlement', settleSeed, [{ col: 'livreurs', id: 'dA' }, { col: 'livreurs', id: 'dB' }],
    (w) => w.settle({ action: 'approve' }),
    (w, n) => { assert.equal(w.db.store.get('transfer_settlements/o1').status, 'settled', n); assert.equal(journals(w.db).length, 2, n); });
  const w = settleSeed(); arrange.quarantine(w.db, 'livreurs', 'dB');
  await assert.rejects(() => w.settle({ action: 'approve' }), closed);
  assert.equal(w.db.store.get('transfer_settlements/o1').status, 'pending_review');
  assert.equal(w.db.store.get('orders/o1').settlementHold, true);
});

test('transferSettlement : permissions et régularisation puis retry = deux crédits, jamais quatre', async () => {
  const w = settleSeed(); const before = snap(w.db);
  for (const uid of ['sub', 'dA', 'dB']) await assert.rejects(() => w.settle({ action: 'approve' }, uid));
  assert.equal(snap(w.db), before);
  arrange.sealed(w.db, 'livreurs', 'dA');
  await assert.rejects(() => w.settle({ action: 'approve' }), closed);
  w.db.store.delete('account_tombstones/dA'); // simulation de test (compte réellement actif)
  await w.settle({ action: 'approve' });
  await w.settle({ action: 'approve' }).catch(() => {}); // rejeu : sans effet
  assert.equal(journals(w.db).length, 2);
  assert.equal(w.db.store.get('livreurs/dA').wallet + w.db.store.get('livreurs/dB').wallet, 300 + 1000);
});

test('transferSettlement cash : aucun mouvement de wallet, donc aucune garde de bénéficiaire (inchangé)', async () => {
  const w = settleSeed();
  const order = w.db.store.get('orders/o1');
  w.db.store.set('transfer_settlements/o1', settlementDocument('o1', order, 'cash', 1000));
  arrange.sealed(w.db, 'livreurs', 'dA');
  const r = await w.settle({ action: 'approve' });
  assert.equal(r.status, 'cash_pending');
  assert.equal(journals(w.db).length, 0);
});
