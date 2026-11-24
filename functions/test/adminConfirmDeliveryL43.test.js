'use strict';

// L4.3 — adminConfirmDeliveryCF : partenaire ET livreur vérifiés dans la même transaction ; l'un des deux fermé, absent ou illisible
// => refus de l'opération entière, aucun crédit partiel. Fonctions réelles sur faux Firestore ; données fictives. La concurrence réelle
// avec le scellement est prouvée sur l'émulateur : adminConfirmDeliveryL43.emulator.test.js.
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

const ORDERS = {
  v2: () => ({
    clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
    paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500, totalAmount: 4000, budget: 500,
    shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 100, acceptedAt: ts(T), createdAt: ts(T),
  }),
  legacy: () => ({
    clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'restaurant', sellerType: 'restaurant', sellerId: 'r1',
    paymentMethod: 'wallet', isPaid: true, budget: 700, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA',
    commissionAmount: 100, acceptedAt: ts(T), createdAt: ts(T),
  }),
  cash: () => ({
    clientId: 'c1', driverId: 'dA', status: 'picked_up', pickedUpAt: 1, type: 'delivery', paymentMethod: 'cash', isPaid: false,
    budget: 700, shoppingBudget: 0, acceptedAt: ts(T), createdAt: ts(T),
  }),
};

function world(shape = 'v2', seed = {}) {
  const db = fakeDb({
    'orders/o1': ORDERS[shape](),
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
const core = (w) => JSON.stringify([...w.db.store.entries()].filter(([k]) => !/^reconciliation_flags\//.test(k))
  .map(([k, v]) => (k === 'orders/o1' ? [k, (({ needsReview, reviewReason, reviewFlagId, ...r }) => r)(v)] : [k, v])).sort(([a], [b]) => (a < b ? -1 : 1)));
const journals = (w) => [...w.db.store.keys()].filter((k) => k.includes('/wallet_transactions/'));
const closed = (e) => e.details && e.details.code === 'BENEFICIARY_ACCOUNT_CLOSED';

// État d'un compte (collection, id) : active = rien à faire.
const arrange = {
  active: () => {},
  quarantine: (w, col, id) => w.db.store.set(`account_tombstones/${id}`, tomb()),
  sealed: (w, col, id) => w.db.store.set(`account_tombstones/${id}`, tomb({ phase: 'sealed' })),
  anonymized: (w, col, id) => w.db.store.set(`${col}/${id}`, { ...(w.db.store.get(`${col}/${id}`) || {}), isDeleted: true }),
  absent: (w, col, id) => w.db.store.delete(`${col}/${id}`),
  unreadable: (w, col, id) => w.db.store.set(`account_tombstones/${id}`, tomb({ phase: 'bogus' })),
};
const CAUSE = { quarantine: 'closing', sealed: 'sealed', anonymized: 'anonymized', absent: 'absent', unreadable: 'unreadable' };
const STATES = Object.keys(arrange);

function assertNothingMoved(w, label) {
  assert.equal(get(w, 'orders/o1').status, 'picked_up', label);
  assert.equal(get(w, 'orders/o1').deliveredAt, undefined, label);
  assert.equal(journals(w).length, 0, `${label} : aucun journal de règlement positif`);
  assert.equal(get(w, 'config/az_wallet'), undefined, `${label} : aucune substitution vers AZ`);
  assert.equal(get(w, 'commissions'), undefined, label);
  assert.ok(![...w.db.store.keys()].some((k) => /^order_dispute_decisions\//.test(k)), `${label} : décision non enregistrée comme réglée`);
}

test('matrice complète partenaire × livreur (6 × 6 états, commande v2) : seule la paire active/active est confirmée ; sinon refus intégral, aucun crédit partiel', async () => {
  let ok = 0; let refused = 0;
  for (const ps of STATES) {
    for (const ds of STATES) {
      const label = `partenaire=${ps} livreur=${ds}`;
      const w = world('v2');
      arrange[ps](w, 'restaurants', 'r1'); arrange[ds](w, 'livreurs', 'dA');
      if (ps === 'active' && ds === 'active') {
        await w.confirm();
        assert.equal(get(w, 'orders/o1').status, 'delivered', label);
        assert.equal(get(w, 'restaurants/r1').wallet, 4500, label);
        assert.equal(get(w, 'livreurs/dA').wallet, 1400, label);
        ok += 1;
        continue;
      }
      const before = core(w);
      const tombs = JSON.stringify([...w.db.store.entries()].filter(([k]) => k.startsWith('account_tombstones/')));
      await assert.rejects(() => w.confirm(), (e) => closed(e), label);
      assert.equal(core(w), before, `${label} : aucune écriture hors trace (aucun crédit partiel)`);
      assertNothingMoved(w, label);
      assert.equal(JSON.stringify([...w.db.store.entries()].filter(([k]) => k.startsWith('account_tombstones/'))), tombs, `${label} : aucun compte rouvert`);
      assert.equal(get(w, 'reconciliation_flags/o1_deliver_beneficiary_refused').completed, false, label);
      // un seul état fermé : la cause nommée est celle du compte fermé
      if (ps === 'active' || ds === 'active') {
        const w2 = world('v2'); arrange[ps](w2, 'restaurants', 'r1'); arrange[ds](w2, 'livreurs', 'dA');
        await assert.rejects(() => w2.confirm(), (e) => e.details.cause === CAUSE[ps === 'active' ? ds : ps], label);
      }
      // retry (même requestId) : aucun effet de plus, aucun crédit partiel
      const after = snap(w);
      await assert.rejects(() => w.confirm(), (e) => closed(e), `${label} retry`);
      assert.equal(snap(w), after, `${label} : retry strictement sans effet`);
      refused += 1;
    }
  }
  assert.equal(ok, 1); assert.equal(refused, 35);
});

for (const shape of ['legacy', 'cash']) {
  test(`livreur fermé (${shape}) : refus intégral même quand le partenaire est actif ou qu’il n’y a aucun partenaire à créditer`, async () => {
    for (const ds of STATES.filter((s) => s !== 'active')) {
      const w = world(shape); arrange[ds](w, 'livreurs', 'dA');
      const before = core(w);
      await assert.rejects(() => w.confirm(), (e) => closed(e) && e.details.cause === CAUSE[ds], `${shape}/${ds}`);
      assert.equal(core(w), before, `${shape}/${ds}`);
      assertNothingMoved(w, `${shape}/${ds}`);
      assert.equal(get(w, 'restaurants/r1').wallet, 1000);
    }
  });
}

test('partenaire fermé (legacy) : refus intégral, le livreur actif n’est pas crédité', async () => {
  for (const ps of STATES.filter((s) => s !== 'active')) {
    const w = world('legacy'); arrange[ps](w, 'restaurants', 'r1');
    const before = core(w);
    await assert.rejects(() => w.confirm(), (e) => closed(e), ps);
    assert.equal(core(w), before, ps);
    assert.equal(get(w, 'livreurs/dA').wallet, 900);
  }
});

test('payeur de commission distinct du livreur : fermé => refus ; actif => confirmation normale', async () => {
  const mk = () => {
    const w = world('v2', { 'livreurs/dB': { wallet: 50 } });
    w.db.store.set('orders/o1', { ...ORDERS.v2(), commissionPayerId: 'dB' });
    return w;
  };
  for (const st of ['quarantine', 'sealed', 'anonymized', 'absent', 'unreadable']) {
    const w = mk(); arrange[st](w, 'livreurs', 'dB');
    const before = core(w);
    await assert.rejects(() => w.confirm(), (e) => closed(e) && e.details.id === 'dB', st);
    assert.equal(core(w), before, st);
  }
  const w = mk();
  await w.confirm();
  assert.equal(get(w, 'orders/o1').status, 'delivered');
});

test('erreur Firestore sur le partenaire ou sur le livreur (profil ou tombstone) : refus, aucune écriture', async () => {
  for (const failing of ['restaurants/r1', 'account_tombstones/r1', 'livreurs/dA', 'account_tombstones/dA']) {
    const w = world('v2');
    const run = w.db.runTransaction.bind(w.db);
    w.db.runTransaction = (cb) => run((tx) => cb({ ...tx, get: async (ref) => { if (ref.path === failing) throw new Error('read down'); return tx.get(ref); }, update: tx.update.bind(tx), set: tx.set.bind(tx), create: tx.create && tx.create.bind(tx) }));
    const before = snap(w);
    await assert.rejects(() => w.confirm(), /read down/, failing);
    assert.equal(snap(w), before, failing);
  }
});

test('retry : même requestId après succès = no-op ; après refus puis réparation du refus erroné = un seul crédit chacun', async () => {
  const w = world('v2');
  await w.confirm();
  const after = snap(w);
  await w.confirm();
  assert.equal(snap(w), after);
  assert.equal(get(w, 'restaurants/r1').wallet, 4500);
  assert.equal(get(w, 'livreurs/dA').wallet, 1400);
  assert.equal(journals(w).length, 2, 'un journal par crédit, aucun doublon');

  const w2 = world('v2'); arrange.sealed(w2, 'livreurs', 'dA');
  await assert.rejects(() => w2.confirm(), closed);
  w2.db.store.delete('account_tombstones/dA'); // refus erroné corrigé : le livreur est en réalité actif
  w2.db.store.delete('orders/o1/__x');
  const o = get(w2, 'orders/o1'); w2.db.store.set('orders/o1', { ...o, needsReview: false });
  await w2.confirm();
  assert.equal(get(w2, 'restaurants/r1').wallet, 4500);
  await w2.confirm();
  assert.equal(get(w2, 'restaurants/r1').wallet, 4500, 'aucun double crédit');
  assert.equal(get(w2, 'livreurs/dA').wallet, 1400);
});

test('permissions : sous-admin, client, livreur, inconnu, anonyme, non connecté refusés ; aucune écriture', async () => {
  const w = world('v2');
  const before = snap(w);
  for (const uid of ['sub', 'c1', 'dA', 'nobody']) await assert.rejects(() => w.confirm(uid), undefined, uid);
  const fn = buildDeliverOrder({ db: w.db, admin, HttpsError, onCall: oc, checkRateLimit: async () => {}, logAudit: async () => {}, adminConfirm: true, requireSuperAdmin });
  await assert.rejects(() => fn.run({ auth: null, data: { orderId: 'o1', requestId: REQ, justification: J, evidence: 'client_confirmed' } }), (e) => e.code === 'unauthenticated');
  await assert.rejects(() => fn.run({ auth: { uid: 'root', token: { firebase: { sign_in_provider: 'anonymous' } } }, data: { orderId: 'o1', requestId: REQ, justification: J, evidence: 'client_confirmed' } }), (e) => e.code === 'unauthenticated');
  assert.equal(snap(w), before);
});

test('câblage : livreur, partenaire et payeur sont vérifiés par UN SEUL appel, dans la transaction, avant la première écriture', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'orderActions.js'), 'utf8');
  assert.match(src, /adminBeneficiaries = \[\{ collection: 'livreurs', id: uid \}\]/);
  // L4.5 : cancelOrderTx (mode administratif) porte désormais son propre appel ; on compte celui de buildDeliverOrder seul.
  assert.equal(src.slice(src.indexOf('function buildDeliverOrder')).split('await assertBeneficiariesCreditable(').length, 2, 'un seul appel');
  const i = src.indexOf('await assertBeneficiariesCreditable(tx, db, HttpsError, adminBeneficiaries)');
  const firstWrite = src.indexOf('tx.update(', src.indexOf('runLifecycleTransaction(db, async (tx) => {', src.indexOf('function buildDeliverOrder')));
  assert.ok(i > 0 && firstWrite > i);
});
