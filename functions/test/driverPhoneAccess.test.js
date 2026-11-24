'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { onCall } = require('firebase-functions/v2/https');
const { HttpsError } = require('firebase-functions/v2/https');
const {
  buildGetDriverPhoneForOrder,
  isWithinDeliveredGrace,
  statusAllowsAccess,
} = require('../driverPhoneAccess');

// Faux Firestore minimal : seulement `.collection(name).doc(id).get()`,
// suffisant pour cette callable (aucune transaction, aucune requête).
function makeFakeDb(seed = {}) {
  const store = new Map(Object.entries(seed));
  return {
    store,
    collection: (name) => ({
      doc: (id) => ({
        get: async () => ({
          exists: store.has(`${name}/${id}`),
          data: () => store.get(`${name}/${id}`),
        }),
      }),
    }),
  };
}

const fakeAdmin = {
  firestore: {
    Timestamp: { fromMillis: (ms) => ({ toMillis: () => ms }) },
  },
};

function makeCheckRateLimit() {
  const calls = [];
  const fn = async (uid, action, max, windowSeconds) => { calls.push({ uid, action, max, windowSeconds }); };
  fn.calls = calls;
  return fn;
}

function makeLogAudit() {
  const calls = [];
  const fn = async (details) => { calls.push(details); };
  fn.calls = calls;
  return fn;
}

function buildFn(db, { checkRateLimit, logAudit } = {}) {
  return buildGetDriverPhoneForOrder({
    db, admin: fakeAdmin, onCall, HttpsError,
    checkRateLimit: checkRateLimit || makeCheckRateLimit(),
    logAudit: logAudit || makeLogAudit(),
  });
}

const BASE_SEED = {
  'orders/o1': { clientId: 'c1', driverId: 'd1', sellerId: null, status: 'accepted' },
  'livreurs/d1': { phone: '+2250700000001' },
  'livreurs/d2': { phone: '+2250700000002' },
};

// ── Authentification ─────────────────────────────────────────────────────

test('authentification : appel non authentifié rejeté', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ data: { orderId: 'o1' } }),
    (err) => err.code === 'unauthenticated',
  );
});

test('authentification : utilisateur anonyme avec uid valide, propriétaire de la commande, est autorisé', async () => {
  // L'authentification anonyme Firebase donne un uid réel ; ce callable ne
  // distingue pas anonyme/identifié, seulement la correspondance avec la
  // commande (décision S6.7 §5.A).
  const fn = buildFn(makeFakeDb(BASE_SEED));
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.equal(result.data.phone, '+2250700000001');
});

test('authentification : utilisateur authentifié valide, propriétaire → succès', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.equal(result.success, true);
  assert.equal(result.data.phone, '+2250700000001');
});

// ── Autorisation ──────────────────────────────────────────────────────────

test('autorisation : client propriétaire autorisé (statut accepted)', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.equal(result.data.phone, '+2250700000001');
});

test('autorisation : client d\'une autre commande refusé', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c2' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('autorisation : livreur affecté à la commande refusé (hors périmètre de cette callable)', async () => {
  // S6.7 §5.B : aucun écran livreur ne lit le téléphone via ce mécanisme —
  // exclu par défaut, même pour son propre dossier.
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ auth: { uid: 'd1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('autorisation : livreur non affecté refusé', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ auth: { uid: 'd2' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('autorisation : partenaire (sellerId) propriétaire autorisé', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o2': { sellerId: 's1', driverId: 'd1', status: 'picked_up' },
  });
  const fn = buildFn(db);
  const result = await fn.run({ auth: { uid: 's1' }, data: { orderId: 'o2' } });
  assert.equal(result.data.phone, '+2250700000001');
});

test('autorisation : partenaire d\'une autre commande refusé', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o2': { sellerId: 's1', driverId: 'd1', status: 'picked_up' },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 's2' }, data: { orderId: 'o2' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('autorisation : pharmacie propriétaire (via pharmacies.currentUid) autorisée', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o3': { pharmacieId: 'p1', driverId: 'd1', status: 'accepted' },
    'pharmacies/p1': { currentUid: 'ph-user' },
  });
  const fn = buildFn(db);
  const result = await fn.run({ auth: { uid: 'ph-user' }, data: { orderId: 'o3' } });
  assert.equal(result.data.phone, '+2250700000001');
});

test('autorisation : pharmacie non propriétaire refusée', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o3': { pharmacieId: 'p1', driverId: 'd1', status: 'accepted' },
    'pharmacies/p1': { currentUid: 'ph-user' },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'autre-pharmacie' }, data: { orderId: 'o3' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('autorisation : admin super autorisé, y compris commande annulée (traçabilité)', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o4': { clientId: 'c9', driverId: 'd1', status: 'cancelled' },
    'admins/admin1': { isActive: true, role: 'super' },
  });
  const fn = buildFn(db);
  const result = await fn.run({ auth: { uid: 'admin1' }, data: { orderId: 'o4' } });
  assert.equal(result.data.phone, '+2250700000001');
});

test('autorisation : sous-admin NON traité comme admin (pas de bypass implicite)', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o4': { clientId: 'c9', driverId: 'd1', status: 'cancelled' },
    'admins/sub1': { isActive: true, role: 'sub' },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'sub1' }, data: { orderId: 'o4' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('autorisation : admin inactif refusé', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o4': { clientId: 'c9', driverId: 'd1', status: 'cancelled' },
    'admins/admin1': { isActive: false, role: 'super' },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'admin1' }, data: { orderId: 'o4' } }),
    (err) => err.code === 'permission-denied',
  );
});

// ── Statuts ───────────────────────────────────────────────────────────────

test('statut : en attente (pending) refusé pour le client', async () => {
  const db = makeFakeDb({ 'orders/o5': { clientId: 'c1', status: 'pending' } });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o5' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('statut : broadcast refusé pour le client', async () => {
  const db = makeFakeDb({ 'orders/o6': { clientId: 'c1', status: 'broadcast' } });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o6' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('statut : assigned autorisé', async () => {
  const db = makeFakeDb({ ...BASE_SEED, 'orders/o7': { clientId: 'c1', driverId: 'd1', status: 'assigned' } });
  const fn = buildFn(db);
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o7' } });
  assert.equal(result.data.phone, '+2250700000001');
});

test('statut : accepted autorisé', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.equal(result.success, true);
});

test('statut : picked_up autorisé', async () => {
  const db = makeFakeDb({ ...BASE_SEED, 'orders/o8': { clientId: 'c1', driverId: 'd1', status: 'picked_up' } });
  const fn = buildFn(db);
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o8' } });
  assert.equal(result.success, true);
});

test('statut : delivered dans la fenêtre de grâce autorisé', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o9': {
      clientId: 'c1', driverId: 'd1', status: 'delivered',
      deliveredAt: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 60_000),
    },
  });
  const fn = buildFn(db);
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o9' } });
  assert.equal(result.success, true);
});

test('statut : delivered hors fenêtre de grâce refusé', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o10': {
      clientId: 'c1', driverId: 'd1', status: 'delivered',
      deliveredAt: fakeAdmin.firestore.Timestamp.fromMillis(Date.now() - 6 * 60 * 60 * 1000),
    },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o10' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('statut : delivered sans deliveredAt refusé (donnée manquante ≠ accès accordé)', async () => {
  const db = makeFakeDb({ ...BASE_SEED, 'orders/o11': { clientId: 'c1', driverId: 'd1', status: 'delivered' } });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o11' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('statut : annulée refusée pour le client', async () => {
  const db = makeFakeDb({ ...BASE_SEED, 'orders/o12': { clientId: 'c1', driverId: 'd1', status: 'cancelled' } });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o12' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('statut : réattribution du livreur → la callable retourne le NOUVEAU numéro', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/o13': { clientId: 'c1', driverId: 'd1', status: 'picked_up' },
  });
  const fn = buildFn(db);
  const before = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o13' } });
  assert.equal(before.data.phone, '+2250700000001');

  // Transfert en cours de route : le document `orders` est mis à jour avec le
  // nouveau livreur (comme le ferait driverTransfer.js en production).
  db.store.set('orders/o13', { clientId: 'c1', driverId: 'd2', status: 'picked_up' });

  const after = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o13' } });
  assert.equal(after.data.phone, '+2250700000002');
});

// ── Protections ───────────────────────────────────────────────────────────

test('protection : orderId absent → invalid-argument', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: {} }),
    (err) => err.code === 'invalid-argument',
  );
});

test('protection : orderId de type incorrect → invalid-argument', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 12345 } }),
    (err) => err.code === 'invalid-argument',
  );
});

test('protection : orderId anormalement long → invalid-argument', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'x'.repeat(201) } }),
    (err) => err.code === 'invalid-argument',
  );
});

test('protection : commande inexistante → même code/message qu\'un refus d\'autorisation (anti-énumération)', async () => {
  const fn1 = buildFn(makeFakeDb(BASE_SEED));
  const fn2 = buildFn(makeFakeDb(BASE_SEED));
  let notFoundErr, deniedErr;
  try { await fn1.run({ auth: { uid: 'c1' }, data: { orderId: 'does-not-exist' } }); } catch (e) { notFoundErr = e; }
  try { await fn2.run({ auth: { uid: 'c2' }, data: { orderId: 'o1' } }); } catch (e) { deniedErr = e; }
  assert.equal(notFoundErr.code, 'permission-denied');
  assert.equal(deniedErr.code, 'permission-denied');
  assert.equal(notFoundErr.message, deniedErr.message);
});

test('protection : commande sans driverId → failed-precondition', async () => {
  const db = makeFakeDb({ 'orders/o14': { clientId: 'c1', status: 'assigned' } });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o14' } }),
    (err) => err.code === 'failed-precondition',
  );
});

test('protection : document livreur inexistant → not-found', async () => {
  const db = makeFakeDb({ 'orders/o15': { clientId: 'c1', driverId: 'ghost', status: 'accepted' } });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o15' } }),
    (err) => err.code === 'not-found',
  );
});

test('protection : téléphone absent sur le document livreur → not-found', async () => {
  const db = makeFakeDb({
    'orders/o16': { clientId: 'c1', driverId: 'd3', status: 'accepted' },
    'livreurs/d3': { name: 'Sans numéro' },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o16' } }),
    (err) => err.code === 'not-found',
  );
});

test('protection : accès croisé entre commandes refusé (déjà couvert, revérifié explicitement)', async () => {
  const db = makeFakeDb({
    ...BASE_SEED,
    'orders/oA': { clientId: 'cA', driverId: 'd1', status: 'accepted' },
    'orders/oB': { clientId: 'cB', driverId: 'd2', status: 'accepted' },
  });
  const fn = buildFn(db);
  await assert.rejects(
    () => fn.run({ auth: { uid: 'cA' }, data: { orderId: 'oB' } }),
    (err) => err.code === 'permission-denied',
  );
});

test('protection : rate limit appliqué (checkRateLimit invoqué avec les bons paramètres)', async () => {
  const checkRateLimit = makeCheckRateLimit();
  const fn = buildFn(makeFakeDb(BASE_SEED), { checkRateLimit });
  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.equal(checkRateLimit.calls.length, 1);
  assert.equal(checkRateLimit.calls[0].uid, 'c1');
  assert.equal(checkRateLimit.calls[0].action, 'get_driver_phone_for_order');
});

test('protection : rate limit dépassé → propage resource-exhausted', async () => {
  const checkRateLimit = async () => { throw new HttpsError('resource-exhausted', 'Trop de tentatives.'); };
  const fn = buildFn(makeFakeDb(BASE_SEED), { checkRateLimit });
  await assert.rejects(
    () => fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } }),
    (err) => err.code === 'resource-exhausted',
  );
});

test('protection : audit — succès journalisé avec le bon contexte, sans le numéro', async () => {
  const logAudit = makeLogAudit();
  const fn = buildFn(makeFakeDb(BASE_SEED), { logAudit });
  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.equal(logAudit.calls.length, 1);
  const entry = logAudit.calls[0];
  assert.equal(entry.action, 'get_driver_phone_for_order');
  assert.equal(entry.status, 'success');
  assert.equal(entry.targetId, 'o1');
  assert.equal(entry.userId, 'c1');
});

test('protection : audit — refus également journalisé', async () => {
  const logAudit = makeLogAudit();
  const fn = buildFn(makeFakeDb(BASE_SEED), { logAudit });
  await assert.rejects(() => fn.run({ auth: { uid: 'c2' }, data: { orderId: 'o1' } }));
  assert.equal(logAudit.calls.length, 1);
  assert.equal(logAudit.calls[0].status, 'denied');
});

test('protection : le numéro de téléphone n\'apparaît JAMAIS dans les journaux d\'audit', async () => {
  const logAudit = makeLogAudit();
  const fn = buildFn(makeFakeDb(BASE_SEED), { logAudit });
  await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  const serialized = JSON.stringify(logAudit.calls);
  assert.equal(serialized.includes('+2250700000001'), false);
});

test('protection : la réponse ne contient aucun champ au-delà de `phone`', async () => {
  const fn = buildFn(makeFakeDb(BASE_SEED));
  const result = await fn.run({ auth: { uid: 'c1' }, data: { orderId: 'o1' } });
  assert.deepEqual(Object.keys(result.data), ['phone']);
  assert.deepEqual(Object.keys(result).sort(), ['code', 'data', 'error', 'message', 'success'].sort());
});

// ── Logique pure (sans Cloud Function), pour compléter la couverture ──────

test('logique pure : isWithinDeliveredGrace / statusAllowsAccess', () => {
  const now = Date.now();
  assert.equal(isWithinDeliveredGrace({ status: 'accepted' }), false);
  assert.equal(isWithinDeliveredGrace({ status: 'delivered' }), false); // pas de deliveredAt
  assert.equal(isWithinDeliveredGrace({
    status: 'delivered', deliveredAt: fakeAdmin.firestore.Timestamp.fromMillis(now - 1000),
  }), true);
  assert.equal(statusAllowsAccess('admin', { status: 'cancelled' }), true);
  assert.equal(statusAllowsAccess('client', { status: 'cancelled' }), false);
  assert.equal(statusAllowsAccess('client', { status: 'accepted' }), true);
});
