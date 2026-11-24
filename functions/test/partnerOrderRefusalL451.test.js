'use strict';

// L4.5.1 — refusePartnerOrder : client remboursé et payeur de commission rendu vérifiés dans la transaction, avant toute écriture.
// Un compte fermé, absent ou illisible => refus de tout le refus (commande intacte, aucun crédit partiel, aucun journal). Fonctions
// réelles sur faux Firestore ; données fictives. Concurrence réelle : partnerOrderRefusalL451.emulator.test.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb } = require('./fakeFirestore');
const { admin } = require('./billingWorld');
const { buildPartnerOrderAction } = require('../partnerOrderActions');
const { calculateCommission } = require('../dispatch');
const { requireSuperAdmin } = require('../adminGuards');

const oc = (...a) => ({ run: a[a.length - 1] });
const authOf = (uid, provider = 'password') => ({ uid, token: { firebase: { sign_in_provider: provider } } });
const ts = (ms) => ({ toMillis: () => ms });
const T = Date.parse('2026-07-01T00:00:00Z');
const tomb = (over = {}) => ({ createdAt: ts(T + 1000), state: 'deleting', ...over });

const v2 = (extra = {}) => ({
  id: 'o1', clientId: 'c1', driverId: 'dA', status: 'accepted', type: 'restaurant', sellerType: 'restaurant',
  sellerId: 'r1', paymentMethod: 'wallet', isPaid: true, amountsVersion: 2, productAmount: 3500, deliveryFee: 500,
  totalAmount: 4000, budget: 500, shoppingBudget: 0, commissionStatus: 'charged', commissionPayerId: 'dA',
  commissionAmount: 100, createdAt: ts(T), ...extra,
});

function world(order = v2(), seed = {}) {
  const db = fakeDb({
    'orders/o1': order,
    'clients/c1': { wallet: 16000, name: 'Aya' },
    'restaurants/r1': { name: 'Chez Test', wallet: 1000, isActive: true },
    'restaurants/r2': { name: 'Autre', wallet: 0, isActive: true },
    'livreurs/dA': { wallet: 900, isOnDelivery: true, currentOrderId: 'o1', isOnline: true },
    'livreurs/dP': { wallet: 500, isOnline: true },
    'admins/root': { role: 'super', isActive: true },
    ...seed,
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const audits = [];
  const fn = buildPartnerOrderAction({
    db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, calculateCommission,
    onCall: oc, requireSuperAdmin, now: () => 1000, isEnabled: () => true,
  }).run;
  return {
    db, audits, s: db.store,
    refuse: (uid = 'r1') => fn({ auth: authOf(uid), data: { orderId: 'o1', action: 'refusePartnerOrder', reason: 'Rupture de stock' } }),
  };
}

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
// Refus acceptable : garde L4.5.1, ou (profil absent) message historique « introuvable » d'un chemin antérieur à la garde.
const isRefusal = (r) => r.success === false && ['BENEFICIARY_ACCOUNT_CLOSED'].includes(r.code);

test('refus partenaire, tous comptes actifs : client remboursé 4000, commission 100 rendue au payeur, une seule fois', async () => {
  const w = world();
  const r = await w.refuse();
  assert.equal(r.success, true);
  assert.equal(w.s.get('orders/o1').status, 'cancelled');
  assert.equal(w.s.get('clients/c1').wallet, 20000);
  assert.equal(w.s.get('livreurs/dA').wallet, 1000);
  assert.equal(w.s.get('restaurants/r1').wallet, 1000, 'partenaire non débité');
  const j = journals(w.db).length;
  const again = await w.refuse();
  assert.equal(again.data.replay, true);
  assert.equal(w.s.get('clients/c1').wallet, 20000);
  assert.equal(journals(w.db).length, j);
});

test('client × payeur de commission (= livreur) : 36 combinaisons — seule active/active passe ; sinon rien ne bouge (essai répété)', async () => {
  for (const sc of STATES) {
    for (const sp of STATES) {
      const w = world();
      arrange[sc](w.db, 'clients', 'c1'); arrange[sp](w.db, 'livreurs', 'dA');
      const label = `client ${sc} / payeur ${sp}`;
      if (sc === 'active' && sp === 'active') { assert.equal((await w.refuse()).success, true, label); continue; }
      const before = snap(w.db);
      for (let i = 0; i < 2; i += 1) {
        const r = await w.refuse();
        assert.equal(r.success, false, label);
        assert.equal(r.code, 'BENEFICIARY_ACCOUNT_CLOSED', label);
        assert.equal(snap(w.db), before, `${label} : rien n'a bougé (essai ${i + 1})`);
      }
      assert.equal(journals(w.db).length, 0, label);
      assert.equal(w.s.get('orders/o1').partnerRefusal, undefined, label);
    }
  }
});

test('payeur de commission DISTINCT du livreur : client × payeur (36) ; livreur fermé mais payeur actif et client actif => refus passe', async () => {
  for (const sc of STATES) {
    for (const sp of STATES) {
      const w = world(v2({ commissionPayerId: 'dP' }));
      arrange[sc](w.db, 'clients', 'c1'); arrange[sp](w.db, 'livreurs', 'dP');
      const label = `client ${sc} / payeur distinct ${sp}`;
      if (sc === 'active' && sp === 'active') {
        assert.equal((await w.refuse()).success, true, label);
        assert.equal(w.s.get('livreurs/dP').wallet, 600, label);
        continue;
      }
      const before = snap(w.db);
      const r = await w.refuse();
      assert.equal(r.code, 'BENEFICIARY_ACCOUNT_CLOSED', label);
      assert.equal(snap(w.db), before, label);
    }
  }
});

test('commande sans livreur (aucun payeur) : client fermé => refus ; commande cash (aucun remboursement) : client fermé n’empêche pas le refus', async () => {
  for (const s of STATES.filter((x) => x !== 'active')) {
    const w = world(v2({ status: 'pending', driverId: undefined, commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined }));
    arrange[s](w.db, 'clients', 'c1');
    const before = snap(w.db);
    const r = await w.refuse();
    assert.equal(r.code, 'BENEFICIARY_ACCOUNT_CLOSED', s);
    assert.equal(snap(w.db), before, s);
  }
  const cash = world(v2({ paymentMethod: 'cash', isPaid: false, status: 'pending', driverId: undefined, commissionStatus: undefined, commissionPayerId: undefined, commissionAmount: undefined }));
  arrange.sealed(cash.db, 'clients', 'c1');
  const r = await cash.refuse();
  assert.equal(r.success, true);
  assert.equal(cash.s.get('clients/c1').wallet, 16000, 'aucun crédit au client fermé');
  assert.equal(journals(cash.db).length, 0);
});

test('aucun débit vendeur : le partenaire (restaurants/r1) n’est jamais débité, même fermé ; erreur de lecture => refus sans écriture', async () => {
  const w = world();
  arrange.sealed(w.db, 'restaurants', 'r1');
  // Partenaire en quarantaine : l'acteur est lui-même verrouillé par les gardes d'entrée existantes ou refusé; aucun mouvement de son wallet.
  const before = snap(w.db);
  await w.refuse().catch(() => {});
  assert.equal(w.s.get('restaurants/r1').wallet, 1000);
  void before;
  const x = world();
  const orig = x.db.runTransaction;
  x.db.runTransaction = (cb) => orig((tx) => cb(new Proxy(tx, {
    get: (t, k) => (k === 'get' ? async (ref) => { if (/account_tombstones\/c1$/.test(ref.path || '')) throw new Error('boom'); return t.get(ref); } : (typeof t[k] === 'function' ? t[k].bind(t) : t[k])),
  })));
  const b = snap(x.db);
  await assert.rejects(() => x.refuse(), /boom/);
  assert.equal(snap(x.db), b);
});

test('régularisation puis retry : un seul remboursement ; permissions : autre partenaire, client, livreur, anonyme refusés sans écriture', async () => {
  const w = world();
  arrange.quarantine(w.db, 'clients', 'c1');
  assert.equal((await w.refuse()).code, 'BENEFICIARY_ACCOUNT_CLOSED');
  w.s.delete('account_tombstones/c1'); // simulation de test : compte réellement actif (un vrai tombstone n'est jamais supprimé)
  assert.equal((await w.refuse()).success, true);
  await w.refuse();
  assert.equal(w.s.get('clients/c1').wallet, 20000);
  const p = world(); const before = snap(p.db);
  for (const uid of ['r2', 'c1', 'dA', 'inconnu']) {
    const r = await p.refuse(uid);
    assert.equal(r.success, false, uid);
  }
  await assert.rejects(() => buildPartnerOrderAction({
    db: p.db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, calculateCommission, onCall: oc, requireSuperAdmin, now: () => 1000, isEnabled: () => true,
  }).run({ auth: authOf('r1', 'anonymous'), data: { orderId: 'o1', action: 'refusePartnerOrder' } }));
  assert.equal(snap(p.db), before);
});

test('câblage : le refus partenaire passe en mode « tous les bénéficiaires » ; les autres appels à cancelOrderTx gardent leur mode', () => {
  const fs = require('node:fs'); const path = require('node:path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'partnerOrderActions.js'), 'utf8');
  assert.match(src, /reason: 'partner_refused',[\s\S]{0,700}closure: \{ admin: true, HttpsError \}/);
  const oa = fs.readFileSync(path.join(__dirname, '..', 'orderActions.js'), 'utf8');
  assert.match(oa, /reason: 'client_cancel', closure: \{ fn: 'cancelOrderCF', HttpsError \}/);
  void isRefusal;
});
