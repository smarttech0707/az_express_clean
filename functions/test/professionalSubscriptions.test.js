'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildManageProfessionalSubscription, ADMIN_PERMISSIONS } = require('../professionalSubscriptions');

function makeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  function snapshot(path) {
    return { exists: store.has(path), data: () => store.get(path) };
  }
  function ref(path) {
    return {
      id: path.split('/').pop(), path,
      get: async () => snapshot(path),
      collection: (name) => collection(`${path}/${name}`),
    };
  }
  function collection(path) {
    return { doc: (id) => ref(`${path}/${id}`) };
  }
  return {
    store,
    collection,
    runTransaction: async (fn) => fn({
      get: async (document) => snapshot(document.path),
      update: (document, values) => store.set(document.path, {
        ...store.get(document.path), ...values,
      }),
      set: (document, values) => store.set(document.path, values),
    }),
  };
}

function harness(seed) {
  const db = makeDb(seed);
  let now = 2_000_000_000_000;
  const originalNow = Date.now;
  Date.now = () => now;
  const handler = buildManageProfessionalSubscription({
    db,
    auth: {},
    timestamp: { fromMillis: (value) => ({ toMillis: () => value }) },
    fieldValue: { serverTimestamp: () => 'SERVER_TIME' },
  });
  return {
    db, handler,
    restore: () => { Date.now = originalNow; },
    setNow: (value) => { now = value; },
  };
}

function ownerRequest(data = {}, uid = 'seller-1') {
  return {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    data: { action: 'renew', collection: 'sellers', docId: 'seller-1', ...data },
  };
}

test('mapping des permissions admin couvre exactement chaque collection professionnelle', () => {
  assert.deepEqual(ADMIN_PERMISSIONS, {
    sellers: 'demandes_vendeurs',
    restaurants: 'restaurants',
    boulangeries: 'boulangeries',
    ekbine_agents: 'ekbine',
    fleet_owners: 'flottes',
  });
});

test('renouvellement: debite et modifie abonnement uniquement dans la transaction serveur', async (t) => {
  const h = harness({
    'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(h.restore);
  const result = await h.handler(ownerRequest());
  assert.equal(result.chargedAmount, 1000);
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 4000);
  assert.equal(h.db.store.get('sellers/seller-1').subscriptionStatus, 'active');
  assert.ok([...h.db.store.keys()].some((key) => key.includes('/wallet_transactions/')));
  assert.ok([...h.db.store.keys()].some((key) => key.startsWith('subscription_audit_logs/')));
});

test('idempotence: deux appels du meme cycle ne debitent qu une fois', async (t) => {
  const h = harness({
    'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(h.restore);
  await h.handler(ownerRequest());
  const second = await h.handler(ownerRequest());
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 4000);
  assert.equal(second.chargedAmount, 0);
  assert.equal(second.outcome, 'unchanged');
});

test('un controle avant echeance ne bloque pas le renouvellement futur', async (t) => {
  const future = 2_000_000_100_000;
  const h = harness({
    'sellers/seller-1': {
      wallet: 5000,
      subscriptionStatus: 'active',
      subscriptionExpiresAt: { toMillis: () => future },
    },
  });
  t.after(h.restore);
  const early = await h.handler(ownerRequest());
  assert.equal(early.outcome, 'unchanged');
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 5000);
  h.setNow(future + 1);
  const due = await h.handler(ownerRequest());
  assert.equal(due.outcome, 'renewed');
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 4000);
});

test('une recharge apres solde insuffisant autorise un nouvel essai', async (t) => {
  const h = harness({
    'sellers/seller-1': { wallet: 100, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(h.restore);
  await h.handler(ownerRequest());
  h.db.store.set('sellers/seller-1', {
    ...h.db.store.get('sellers/seller-1'), wallet: 2100,
  });
  const retry = await h.handler(ownerRequest());
  assert.equal(retry.outcome, 'renewed');
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 1100);
});

test('solde insuffisant: aucun debit et suspension explicite', async (t) => {
  const h = harness({
    'sellers/seller-1': { wallet: 100, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(h.restore);
  const result = await h.handler(ownerRequest());
  assert.equal(result.outcome, 'insufficient_funds');
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 100);
  assert.equal(h.db.store.get('sellers/seller-1').subscriptionStatus, 'suspended');
});

test('E-Kbine utilise le tarif et le champ wallet serveur dedies', async (t) => {
  const h = harness({
    'ekbine_agents/agent-1': { walletBalance: 900, subscriptionStatus: 'active' },
  });
  t.after(h.restore);
  const result = await h.handler(ownerRequest({
    collection: 'ekbine_agents', docId: 'agent-1',
  }, 'agent-1'));
  assert.equal(result.chargedAmount, 500);
  assert.equal(h.db.store.get('ekbine_agents/agent-1').walletBalance, 400);
  assert.equal(h.db.store.get('ekbine_agents/agent-1').wallet, undefined);
});

test('un proprietaire ne peut jamais renouveler le compte d un tiers', async (t) => {
  const h = harness({ 'sellers/victim': { wallet: 5000 } });
  t.after(h.restore);
  await assert.rejects(
    h.handler(ownerRequest({ docId: 'victim' })),
    (error) => error.code === 'permission-denied',
  );
  assert.equal(h.db.store.get('sellers/victim').wallet, 5000);
});

test('restaurant: association owner vers restaurant obligatoire', async (t) => {
  const h = harness({
    'restaurant_owners/owner-1': { restaurantId: 'resto-1' },
    'restaurants/resto-1': { wallet: 2000 },
  });
  t.after(h.restore);
  await h.handler(ownerRequest({ collection: 'restaurants', docId: 'resto-1' }, 'owner-1'));
  assert.equal(h.db.store.get('restaurants/resto-1').wallet, 1000);
});

test('action admin refusee a un non-admin', async (t) => {
  const h = harness({ 'sellers/seller-1': { wallet: 5000 } });
  t.after(h.restore);
  await assert.rejects(h.handler(ownerRequest({
    action: 'activateVip', requestId: '1234567890abcdef', chargeWallet: true,
  })), (error) => error.code === 'permission-denied');
});

test('action admin idempotente: le meme requestId ne facture qu une fois', async (t) => {
  const h = harness({
    'admins/admin-1': { role: 'super', isActive: true },
    'sellers/seller-1': { wallet: 5000 },
  });
  t.after(h.restore);
  const request = ownerRequest({
    action: 'activateVip', requestId: '1234567890abcdef', chargeWallet: true,
  }, 'admin-1');
  await h.handler(request);
  const second = await h.handler(request);
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 3000);
  assert.equal(second.idempotent, true);
});

test('action admin requires the permission mapped to its collection', async (t) => {
  const h = harness({
    'admins/sub-1': { role: 'sub', isActive: true, permissions: ['restaurants'] },
    'sellers/seller-1': { wallet: 5000 },
  });
  t.after(h.restore);
  await assert.rejects(h.handler(ownerRequest({
    action: 'activateStandard', requestId: '1234567890abcdef', chargeWallet: false,
  }, 'sub-1')), (error) => error.code === 'permission-denied');
});

// Décision : activations (gratuites ou payantes), essai et VIP = super-admin
// seul ; le sous-admin de la catégorie garde les actions de protection.
test('sous-admin avec la bonne permission : AUCUNE activation d\'abonnement, VIP ou essai', async (t) => {
  for (const [action, extra] of [
    ['activateStandard', { chargeWallet: false }], ['activateStandard', { chargeWallet: true }],
    ['activateVip', { chargeWallet: false }], ['activateVip', { chargeWallet: true }],
    ['activateTrial', {}], ['activateStandard', {}],
  ]) {
    const h = harness({
      'admins/sub-1': { role: 'sub', isActive: true, permissions: ['demandes_vendeurs'] },
      'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'expired', vipStatus: 'none' },
    });
    t.after(h.restore);
    await assert.rejects(h.handler(ownerRequest({
      action, requestId: '1234567890abcdef', ...extra,
    }, 'sub-1')), (error) => error.code === 'permission-denied', `${action} ${JSON.stringify(extra)}`);
    assert.deepEqual(h.db.store.get('sellers/seller-1'),
      { wallet: 5000, subscriptionStatus: 'expired', vipStatus: 'none' });
    assert.ok(![...h.db.store.keys()].some((key) => key.includes('/wallet_transactions/')));
  }
});

test('sous-admin avec la bonne permission : suspension et retrait du VIP restent permis', async (t) => {
  for (const action of ['suspend', 'deactivateVip']) {
    const h = harness({
      'admins/sub-1': { role: 'sub', isActive: true, permissions: ['demandes_vendeurs'] },
      'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', vipStatus: 'vip' },
    });
    t.after(h.restore);
    const result = await h.handler(ownerRequest({ action, requestId: '1234567890abcdef' }, 'sub-1'));
    assert.ok(result.outcome, action);
    assert.equal(h.db.store.get('sellers/seller-1').wallet, 5000, 'aucun débit');
  }
});

test('sous-admin sans la permission : suspension refusée aussi', async (t) => {
  const h = harness({
    'admins/sub-1': { role: 'sub', isActive: true, permissions: ['restaurants'] },
    'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active' },
  });
  t.after(h.restore);
  await assert.rejects(h.handler(ownerRequest({ action: 'suspend', requestId: '1234567890abcdef' }, 'sub-1')),
    (error) => error.code === 'permission-denied');
});

test('le super-admin garde toutes les activations', async (t) => {
  for (const [action, extra] of [['activateStandard', { chargeWallet: false }],
    ['activateVip', { chargeWallet: true }], ['activateTrial', {}]]) {
    const h = harness({
      'admins/boss': { role: 'super', isActive: true },
      'sellers/seller-1': { wallet: 5000 },
    });
    t.after(h.restore);
    const result = await h.handler(ownerRequest({ action, requestId: '1234567890abcdef', ...extra }, 'boss'));
    assert.ok(result.outcome, action);
  }
});

test('session anonyme refusee avant toute lecture ou ecriture sensible', async (t) => {
  const h = harness({ 'sellers/seller-1': { wallet: 5000 } });
  t.after(h.restore);
  const request = ownerRequest();
  request.auth.token.firebase.sign_in_provider = 'anonymous';
  await assert.rejects(h.handler(request), (error) => error.code === 'unauthenticated');
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 5000);
});

test('suppression en cours ou compte supprimé : aucun débit ni renouvellement, solde inchangé', async (t) => {
  for (const flag of [{ deletionRequested: true }, { isDeleted: true }]) {
    const h = harness({
      'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null, ...flag },
    });
    t.after(h.restore);
    await assert.rejects(() => h.handler(ownerRequest()), (e) => e.code === 'failed-precondition');
    assert.equal(h.db.store.get('sellers/seller-1').wallet, 5000);
    assert.equal(h.db.store.get('sellers/seller-1').subscriptionStatus, 'active');
    assert.equal([...h.db.store.keys()].some((k) => k.startsWith('subscription_operations/')), false);
  }
});

// S4 : renouveler le compte d'AUTRUI (débit de son wallet) exige la permission
// de la catégorie ; être « un admin actif quelconque » ne suffit plus.
test('S4 : sous-admin sans la permission de la catégorie ne renouvelle pas un compte tiers', async (t) => {
  const h = harness({
    'admins/sub-1': { role: 'sub', isActive: true, permissions: ['restaurants', 'recharges'] },
    'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(h.restore);
  await assert.rejects(h.handler(ownerRequest({}, 'sub-1')),
    (error) => error.code === 'permission-denied');
  assert.equal(h.db.store.get('sellers/seller-1').wallet, 5000);
  assert.ok(![...h.db.store.keys()].some((key) => key.includes('/wallet_transactions/')));
});

test('S4 : sous-admin désactivé, rôle inconnu ou simple client : aucun renouvellement d\'autrui', async (t) => {
  for (const admin of [
    { role: 'sub', isActive: false, permissions: ['demandes_vendeurs'] },
    { role: 'other', isActive: true, permissions: ['demandes_vendeurs'] },
    undefined,
  ]) {
    const h = harness({
      ...(admin ? { 'admins/who': admin } : {}),
      'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
    });
    t.after(h.restore);
    await assert.rejects(h.handler(ownerRequest({}, 'who')),
      (error) => error.code === 'permission-denied');
    assert.equal(h.db.store.get('sellers/seller-1').wallet, 5000);
  }
});

// Débiter le wallet d'un compte tiers est financier : super-admin seul, même
// pour un sous-admin porteur de la permission de la catégorie.
test('renouvellement d\'un compte tiers : super-admin seulement', async (t) => {
  const hSub = harness({
    'admins/adm': { role: 'sub', isActive: true, permissions: ['demandes_vendeurs'] },
    'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(hSub.restore);
  await assert.rejects(hSub.handler(ownerRequest({}, 'adm')), (e) => e.code === 'permission-denied');
  assert.equal(hSub.db.store.get('sellers/seller-1').wallet, 5000);
  const hSuper = harness({
    'admins/adm': { role: 'super', isActive: true },
    'sellers/seller-1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(hSuper.restore);
  const result = await hSuper.handler(ownerRequest({}, 'adm'));
  assert.equal(result.chargedAmount, 1000);
  assert.equal(hSuper.db.store.get('sellers/seller-1').wallet, 4000);
});

test('S4 : le restaurateur propriétaire renouvelle son restaurant, pas celui d\'un autre', async (t) => {
  const h = harness({
    'restaurant_owners/own': { restaurantId: 'r1' },
    'restaurants/r1': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
    'restaurants/r2': { wallet: 5000, subscriptionStatus: 'active', subscriptionExpiresAt: null },
  });
  t.after(h.restore);
  const ok = await h.handler(ownerRequest({ collection: 'restaurants', docId: 'r1' }, 'own'));
  assert.equal(ok.chargedAmount, 1000);
  await assert.rejects(h.handler(ownerRequest({ collection: 'restaurants', docId: 'r2' }, 'own')),
    (error) => error.code === 'permission-denied');
  assert.equal(h.db.store.get('restaurants/r2').wallet, 5000);
});
