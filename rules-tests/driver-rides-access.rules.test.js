// « Mes courses » (livreur) : les requêtes de l'écran (lib/screens/driver/driver_rides_service.dart) doivent être
// acceptées pour le livreur concerné SEUL, et les index composites nécessaires doivent exister.
// Les règles de lecture de `orders` ne sont pas modifiées par cette fonctionnalité : ce test les verrouille.
//
// Exécution : npm run test:rules
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const base = { budget: 500, clientId: 'c1', createdAt: new Date('2026-10-31T09:00:00Z') };
    await db.doc('orders/o-deliv-1').set({ ...base, driverId: 'd1', status: 'delivered' });
    await db.doc('orders/o-deliv-2').set({ ...base, driverId: 'd1', status: 'delivered', createdAt: new Date('2026-10-30T09:00:00Z') });
    await db.doc('orders/o-prog').set({ ...base, driverId: 'd1', status: 'accepted' });
    await db.doc('orders/o-prog2').set({ ...base, driverId: 'd1', status: 'picked_up' });
    await db.doc('orders/o-canc').set({ ...base, driverId: 'd1', status: 'cancelled', cancelReason: 'no_driver_found' });
    await db.doc('orders/o-other').set({ ...base, driverId: 'd2', status: 'delivered' });
    // Refus : le serveur supprime driverId (functions/driverDecline.js) → plus lisible par ce livreur.
    await db.doc('orders/o-declined').set({ ...base, status: 'pending', excludedDriverIds: ['d1'] });
    await db.doc('livreurs/d1/wallet_transactions/t1').set({ type: 'earning', amount: 400, orderId: 'o-deliv-1' });
    await db.doc('livreurs/d2/wallet_transactions/t2').set({ type: 'earning', amount: 400, orderId: 'o-other' });
  });
  return e;
}

const ids = (snap) => snap.docs.map((d) => d.id).sort();
const ordersOf = (db, uid) => db.collection('orders').where('driverId', '==', uid);

test('les requêtes des 4 onglets (propre driverId) sont acceptées et ne renvoient que ses courses', async () => {
  const e = await env('az-rides-own');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    const all = await assertSucceeds(ordersOf(db, 'd1').orderBy('createdAt', 'desc').limit(20).get());
    assert.deepStrictEqual(ids(all), ['o-canc', 'o-deliv-1', 'o-deliv-2', 'o-prog', 'o-prog2']);
    const delivered = await assertSucceeds(
      ordersOf(db, 'd1').where('status', '==', 'delivered').orderBy('createdAt', 'desc').limit(20).get());
    assert.deepStrictEqual(ids(delivered), ['o-deliv-1', 'o-deliv-2']);
    const cancelled = await assertSucceeds(
      ordersOf(db, 'd1').where('status', '==', 'cancelled').orderBy('createdAt', 'desc').limit(20).get());
    assert.deepStrictEqual(ids(cancelled), ['o-canc']);
    const inProgress = await assertSucceeds(
      ordersOf(db, 'd1').where('status', 'in', ['accepted', 'picked_up']).orderBy('createdAt', 'desc').limit(20).get());
    assert.deepStrictEqual(ids(inProgress), ['o-prog', 'o-prog2']);
  } finally { await e.cleanup(); }
});

test('pagination : la page suivante (startAfter) reste dans les courses du livreur', async () => {
  const e = await env('az-rides-page');
  try {
    const db = e.authenticatedContext('d1', password).firestore();
    const first = await assertSucceeds(
      ordersOf(db, 'd1').where('status', '==', 'delivered').orderBy('createdAt', 'desc').limit(1).get());
    assert.strictEqual(first.docs.length, 1);
    const next = await assertSucceeds(
      ordersOf(db, 'd1').where('status', '==', 'delivered').orderBy('createdAt', 'desc').startAfter(first.docs[0]).limit(1).get());
    assert.deepStrictEqual(ids(next), ['o-deliv-2']);
  } finally { await e.cleanup(); }
});

test('un livreur ne peut pas lire les courses d\'un autre livreur', async () => {
  const e = await env('az-rides-other');
  try {
    const d1 = e.authenticatedContext('d1', password).firestore();
    await assertFails(ordersOf(d1, 'd2').orderBy('createdAt', 'desc').limit(20).get());
    await assertFails(ordersOf(d1, 'd2').where('status', '==', 'delivered').orderBy('createdAt', 'desc').get());
    await assertFails(d1.doc('orders/o-other').get());
    // Sans filtre driverId : liste interdite (impossible de parcourir toutes les commandes).
    await assertFails(d1.collection('orders').orderBy('createdAt', 'desc').limit(20).get());
    await assertFails(d1.collection('orders').where('status', '==', 'delivered').get());
  } finally { await e.cleanup(); }
});

test('sans connexion : aucune course lisible', async () => {
  const e = await env('az-rides-unauth');
  try {
    const db = e.unauthenticatedContext().firestore();
    await assertFails(ordersOf(db, 'd1').orderBy('createdAt', 'desc').limit(20).get());
  } finally { await e.cleanup(); }
});

test('un refus (driverId retiré par le serveur) n\'est PAS lisible par le livreur : onglet Refusées sans requête', async () => {
  const e = await env('az-rides-declined');
  try {
    const d1 = e.authenticatedContext('d1', password).firestore();
    await assertFails(d1.doc('orders/o-declined').get());
    const all = await assertSucceeds(ordersOf(d1, 'd1').get());
    assert.ok(!ids(all).includes('o-declined'));
  } finally { await e.cleanup(); }
});

test('gains : lecture des crédits du portefeuille du livreur seul', async () => {
  const e = await env('az-rides-earnings');
  try {
    const d1 = e.authenticatedContext('d1', password).firestore();
    const own = await assertSucceeds(
      d1.collection('livreurs/d1/wallet_transactions').where('type', '==', 'earning').where('orderId', 'in', ['o-deliv-1', 'o-deliv-2']).get());
    assert.deepStrictEqual(ids(own), ['t1']);
    await assertFails(d1.collection('livreurs/d2/wallet_transactions').where('type', '==', 'earning').get());
    // Limite connue (règle existante, non modifiée ici) : le propriétaire peut créer des entrées de journal
    // `wallet_transactions` ; c'est pourquoi l'écran n'affiche un gain que s'il est unique ET égal au budget de la
    // course (voir reliableEarnings). L'écran lui-même ne fait aucune écriture (vérifié par test Dart).
  } finally { await e.cleanup(); }
});

test('index composites requis par « Mes courses » présents dans firestore.indexes.json', () => {
  const { indexes } = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'firestore.indexes.json'), 'utf8'));
  const has = (...fields) => indexes.some((i) => i.collectionGroup === 'orders' && i.queryScope === 'COLLECTION' &&
    JSON.stringify(i.fields.map((f) => [f.fieldPath, f.order])) === JSON.stringify(fields));
  assert.ok(has(['driverId', 'ASCENDING'], ['createdAt', 'DESCENDING']), 'Toutes : driverId + createdAt desc');
  assert.ok(has(['driverId', 'ASCENDING'], ['status', 'ASCENDING'], ['createdAt', 'DESCENDING']),
    'En cours / Terminées / Annulées : driverId + status + createdAt desc');
});
