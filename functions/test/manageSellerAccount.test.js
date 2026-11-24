'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildManageSellerAccount } = require('../manageSellerAccount');

class FakeHttpsError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function harness({ seller, permissionError = null, rateError = null } = {}) {
  const store = new Map();
  if (seller) store.set('sellers/s1', seller);
  const audits = [];
  const db = {
    collection: (name) => ({ doc: (id) => ({ path: `${name}/${id}` }) }),
    runTransaction: async (fn) => fn({
      get: async (ref) => ({ exists: store.has(ref.path), data: () => store.get(ref.path) }),
      update: (ref, values) => store.set(ref.path, { ...store.get(ref.path), ...values }),
    }),
  };
  const handler = buildManageSellerAccount({
    db,
    admin: { firestore: { FieldValue: { serverTimestamp: () => 'SERVER_TIME' } } },
    HttpsError: FakeHttpsError,
    requireAdminPermission: async () => { if (permissionError) throw permissionError; },
    checkRateLimit: async () => { if (rateError) throw rateError; },
    logAudit: async (entry) => audits.push(entry),
  });
  return { handler, store, audits };
}

const req = (data, uid = 'admin-1') => ({ auth: { uid }, data });
const seller = {
  name: 'Boutique', phone: '0700000000', type: 'boutique', isActive: true, lat: 6.7, lng: -3.4,
  wallet: 5000, subscriptionStatus: 'active', vipStatus: 'none',
};

test('mise à jour de fiche : champs modifiés, audit avec ancienne/nouvelle valeur non sensibles', async () => {
  const h = harness({ seller: { ...seller } });
  const out = await h.handler(req({ action: 'updateProfile', sellerId: 's1',
    profile: { name: 'Nouveau nom', phone: '0711 11 11 11', lat: 6.8, lng: -3.5 } }));
  assert.equal(out.success, true);
  assert.equal(out.code, 'OK');
  const saved = h.store.get('sellers/s1');
  assert.equal(saved.name, 'Nouveau nom');
  assert.equal(saved.phone, '0711111111');
  assert.equal(saved.updatedAt, 'SERVER_TIME');
  assert.equal(saved.lastModifiedBy, 'admin-1');
  // Jamais touchés :
  assert.equal(saved.wallet, 5000);
  assert.equal(saved.subscriptionStatus, 'active');
  assert.equal(saved.vipStatus, 'none');
  const audit = h.audits.at(-1);
  assert.equal(audit.action, 'seller_profile_update');
  assert.equal(audit.userId, 'admin-1');
  assert.equal(audit.targetId, 's1');
  assert.equal(audit.status, 'success');
  assert.deepEqual(audit.metadata.before, { name: 'Boutique', lat: 6.7, lng: -3.4 });
  assert.deepEqual(audit.metadata.after, { name: 'Nouveau nom', lat: 6.8, lng: -3.5 });
  assert.equal(audit.metadata.phoneChanged, true);
  // Le téléphone ne figure jamais dans le journal.
  assert.ok(!JSON.stringify(audit).includes('0711111111'));
  assert.ok(!JSON.stringify(audit).includes('0700000000'));
});

test('activation / désactivation tracées', async () => {
  const h = harness({ seller: { ...seller } });
  await h.handler(req({ action: 'setActive', sellerId: 's1', isActive: false }));
  assert.equal(h.store.get('sellers/s1').isActive, false);
  assert.equal(h.audits.at(-1).action, 'seller_set_active');
  assert.deepEqual(h.audits.at(-1).metadata.before, { isActive: true });
  assert.deepEqual(h.audits.at(-1).metadata.after, { isActive: false });
});

test('aucune modification : succès « unchanged » et trace', async () => {
  const h = harness({ seller: { ...seller } });
  const out = await h.handler(req({ action: 'setActive', sellerId: 's1', isActive: true }));
  assert.deepEqual(out.data.changedFields, []);
  assert.equal(h.audits.at(-1).metadata.result, 'unchanged');
});

test('champs financiers ou inconnus refusés, rien n\'est écrit, échec journalisé', async () => {
  for (const profile of [{ wallet: 999999 }, { subscriptionStatus: 'active' }, { vipStatus: 'vip' },
    { isSuspended: true }, { status: 'x' }, { name: 'ok', wallet: 1 }, { $set: 1 }]) {
    const h = harness({ seller: { ...seller } });
    await assert.rejects(h.handler(req({ action: 'updateProfile', sellerId: 's1', profile })),
      (e) => e.code === 'invalid-argument');
    assert.deepEqual(h.store.get('sellers/s1'), seller);
    assert.equal(h.audits.at(-1).action, 'seller_account_failed');
    assert.equal(h.audits.at(-1).status, 'failed');
  }
});

test('valeurs invalides refusées', async () => {
  const bad = [{ name: 'x' }, { name: 'a'.repeat(81) }, { name: 12 }, { phone: 'abc' }, { phone: '123' },
    { type: 'Boutique!' }, { isActive: 'oui' }, { lat: 6.7 }, { lat: 'a', lng: 1 }, { lat: 91, lng: 0 },
    { lat: 0, lng: 0 }, { lat: NaN, lng: 1 }, {}];
  for (const profile of bad) {
    const h = harness({ seller: { ...seller } });
    await assert.rejects(h.handler(req({ action: 'updateProfile', sellerId: 's1', profile })),
      (e) => e.code === 'invalid-argument', JSON.stringify(profile));
    assert.deepEqual(h.store.get('sellers/s1'), seller);
  }
});

test('identifiant / action invalides et vendeur introuvable', async () => {
  const h = harness({ seller: { ...seller } });
  for (const data of [{ action: 'delete', sellerId: 's1' }, { action: 'setActive', sellerId: '' },
    { action: 'setActive', sellerId: 'a/b', isActive: false }, { action: 'setActive' }]) {
    await assert.rejects(h.handler(req(data)), (e) => e.code === 'invalid-argument');
  }
  await assert.rejects(h.handler(req({ action: 'setActive', sellerId: 'nope', isActive: false })),
    (e) => e.code === 'not-found');
});

test('permission refusée : aucune écriture, tentative journalisée', async () => {
  const denied = new FakeHttpsError('permission-denied', 'Permission Admin insuffisante.');
  const h = harness({ seller: { ...seller }, permissionError: denied });
  await assert.rejects(h.handler(req({ action: 'setActive', sellerId: 's1', isActive: false }, 'sub-1')),
    (e) => e.code === 'permission-denied');
  assert.deepEqual(h.store.get('sellers/s1'), seller);
  assert.equal(h.audits.length, 1);
  assert.equal(h.audits[0].action, 'seller_account_denied');
  assert.equal(h.audits[0].status, 'denied');
  assert.equal(h.audits[0].userId, 'sub-1');
});

test('limitation de débit appliquée', async () => {
  const limited = new FakeHttpsError('resource-exhausted', 'Trop de requêtes.');
  const h = harness({ seller: { ...seller }, rateError: limited });
  await assert.rejects(h.handler(req({ action: 'setActive', sellerId: 's1', isActive: false })),
    (e) => e.code === 'resource-exhausted');
  assert.equal(h.store.get('sellers/s1').isActive, true);
});

test('compte en cours de suppression : activation refusée, désactivation permise', async () => {
  const h = harness({ seller: { ...seller, isActive: false, deletionRequested: true } });
  await assert.rejects(h.handler(req({ action: 'setActive', sellerId: 's1', isActive: true })),
    (e) => e.code === 'failed-precondition');
  const h2 = harness({ seller: { ...seller, deletionRequested: true } });
  await h2.handler(req({ action: 'setActive', sellerId: 's1', isActive: false }));
  assert.equal(h2.store.get('sellers/s1').isActive, false);
});
