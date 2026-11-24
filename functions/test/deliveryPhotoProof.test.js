'use strict';

// Mission 7E-11-T — validation serveur de la photo de livraison (deliverOrderCF et ses deux variantes) :
// identité du livreur, commande concernée, chemin Storage attendu, existence du fichier ; compatibilité avec
// les livraisons sans photo et avec les commandes déjà livrées.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildDeliverOrder } = require('../orderActions');
const { requireSuperAdmin } = require('../adminGuards');
const { deliveryPhotoPath, storageObjectOfUrl, deliveryPhotoUrlMatches } = require('../proofStorage');

const ts = (ms) => ({ toMillis: () => ms });
const admin = {
  firestore: {
    Timestamp: { fromMillis: ts },
    FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion, increment: (n) => ({ __increment: n }) },
  },
};
const oc = (...a) => ({ run: a[a.length - 1] });
const BUCKET = 'demo-proj.firebasestorage.app';
const urlOf = (objectPath, { bucket = BUCKET, token = 'tok-1' } = {}) =>
  `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/${encodeURIComponent(objectPath)}?alt=media&token=${token}`;
const GOOD = urlOf('delivery_photos/dA/o1.jpg');
const code = (c) => (e) => e instanceof HttpsError && e.code === c;

function setup({ files = ['delivery_photos/dA/o1.jpg'], check = true, storageError = false, adminConfirm = false } = {}) {
  const db = fakeDb({
    'orders/o1': { clientId: 'c1', driverId: 'dA', status: 'picked_up', paymentMethod: 'cash', budget: 1500 },
    'livreurs/dA': { wallet: 800, isOnDelivery: true, currentOrderId: 'o1' },
    'admins/root': { role: 'super', isActive: true },
  });
  const run = db.runTransaction; let chain = Promise.resolve();
  db.runTransaction = (cb) => { const p = chain.then(() => run(cb)); chain = p.catch(() => {}); return p; };
  const probes = [];
  const deliveryPhotoCheck = check ? {
    bucketName: BUCKET,
    exists: async (p) => { probes.push(p); if (storageError) throw new Error('storage down'); return files.includes(p); },
  } : undefined;
  const common = { db, admin, HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, onCall: oc, deliveryPhotoCheck };
  const deliver = buildDeliverOrder(common).run;
  const confirm = buildDeliverOrder({ ...common, adminConfirm, requireSuperAdmin }).run;
  const auth = (uid) => ({ uid, token: { firebase: { sign_in_provider: 'password' } } });
  return {
    db, probes,
    deliver: (data, uid = 'dA') => deliver({ auth: auth(uid), data: { orderId: 'o1', ...data } }),
    adminConfirm: (data) => confirm({
      auth: auth('root'),
      data: { orderId: 'o1', requestId: 'confirm-id-0000001xxxx', justification: 'Livraison constatée après appel du client', evidence: 'client_confirmed', ...data },
    }),
    order: () => db.store.get('orders/o1'),
    driver: () => db.store.get('livreurs/dA'),
  };
}
const untouched = (t) => { assert.equal(t.order().status, 'picked_up'); assert.equal(t.order().deliveryPhoto, undefined); assert.equal(t.driver().wallet, 800); };

// ── Module pur ───────────────────────────────────────────────────────────────────────────────────────────────────

test('URL de téléchargement : chemin décodé extrait ; hôte, bucket et forme vérifiés', () => {
  assert.equal(storageObjectOfUrl(GOOD, BUCKET), 'delivery_photos/dA/o1.jpg');
  assert.equal(storageObjectOfUrl(GOOD), 'delivery_photos/dA/o1.jpg', 'sans bucket attendu : forme seule');
  assert.equal(deliveryPhotoPath('o1', 'dA'), 'delivery_photos/dA/o1.jpg');
  // Les deux noms du bucket par défaut désignent le même projet (l'application reçoit le sien à la compilation).
  assert.ok(deliveryPhotoUrlMatches(urlOf('delivery_photos/dA/o1.jpg', { bucket: 'demo-proj.appspot.com' }), 'o1', 'dA', BUCKET));
  const bad = [
    undefined, null, '', 42, {}, `${GOOD}${'a'.repeat(2100)}`,
    'http://firebasestorage.googleapis.com/v0/b/demo-proj.firebasestorage.app/o/delivery_photos%2FdA%2Fo1.jpg',
    'https://evil.example/v0/b/demo-proj.firebasestorage.app/o/delivery_photos%2FdA%2Fo1.jpg?alt=media',
    'https://evil.example/delivery_photos/dA/o1.jpg',
    'https://user:pw@firebasestorage.googleapis.com/v0/b/demo-proj.firebasestorage.app/o/delivery_photos%2FdA%2Fo1.jpg',
    urlOf('delivery_photos/dA/o1.jpg', { bucket: 'autre-projet.firebasestorage.app' }),
    'https://firebasestorage.googleapis.com/v0/b/demo-proj.firebasestorage.app/o/delivery_photos/dA/o1.jpg',
    'https://firebasestorage.googleapis.com/v0/b/demo-proj.firebasestorage.app/o/%E0%A4%A',
    'not a url',
  ];
  for (const u of bad) assert.equal(deliveryPhotoUrlMatches(u, 'o1', 'dA', BUCKET), false, String(u).slice(0, 80));
  for (const p of ['delivery_photos/dB/o1.jpg', 'delivery_photos/dA/o2.jpg', 'delivery_photos/dA/o1.jpg.evil', 'delivery_photos/dA/o1.png',
    'delivery_photos/dA/../dB/o1.jpg', 'acceptance_selfies/o1/dA.jpg', 'client_photos/dA/profile.jpg', 'x/delivery_photos/dA/o1.jpg']) {
    assert.equal(deliveryPhotoUrlMatches(urlOf(p), 'o1', 'dA', BUCKET), false, p);
  }
});

// ── deliverOrderCF ───────────────────────────────────────────────────────────────────────────────────────────────

test('photo valide (bon livreur, bonne commande, bon chemin, fichier existant) : livraison enregistrée avec la photo', async () => {
  const t = setup();
  assert.deepEqual(await t.deliver({ deliveryPhotoUrl: GOOD }), { success: true });
  assert.equal(t.order().status, 'delivered');
  assert.equal(t.order().deliveryPhoto, GOOD);
  assert.deepEqual(t.probes, ['delivery_photos/dA/o1.jpg']);
});

test('photo d une autre commande, d un autre livreur, hôte étranger, bucket étranger, extension ou chemin détourné : refusée, rien n est écrit', async () => {
  const t = setup({ files: ['delivery_photos/dA/o2.jpg', 'delivery_photos/dB/o1.jpg', 'delivery_photos/dA/o1.jpg.evil'] });
  for (const u of [
    urlOf('delivery_photos/dA/o2.jpg'), urlOf('delivery_photos/dB/o1.jpg'), urlOf('delivery_photos/dA/o1.jpg.evil'),
    urlOf('acceptance_selfies/o1/dA.jpg'), 'https://evil.example/delivery_photos/dA/o1.jpg', 'https://x/p.jpg',
    urlOf('delivery_photos/dA/o1.jpg', { bucket: 'autre.firebasestorage.app' }), 42, { a: 1 },
  ]) {
    await assert.rejects(t.deliver({ deliveryPhotoUrl: u }), code('invalid-argument'), String(u).slice(0, 70));
  }
  assert.deepEqual(t.probes, [], 'aucune requête Storage pour une URL invalide');
  untouched(t);
});

test('fichier absent de Storage : refusé (failed-precondition), commande et solde intacts', async () => {
  const t = setup({ files: [] });
  await assert.rejects(t.deliver({ deliveryPhotoUrl: GOOD }), code('failed-precondition'));
  untouched(t);
});

test('panne Storage : erreur réessayable (unavailable) AVANT toute écriture, jamais une livraison à moitié faite', async () => {
  const t = setup({ storageError: true });
  await assert.rejects(t.deliver({ deliveryPhotoUrl: GOOD }), code('unavailable'));
  untouched(t);
});

test('livraison sans photo (anciennes applications, photo non exigée) : inchangée, aucune requête Storage, aucun champ deliveryPhoto', async () => {
  for (const data of [{}, { deliveryPhotoUrl: undefined }, { deliveryPhotoUrl: null }, { deliveryPhotoUrl: '' }]) {
    const t = setup({ files: [] });
    assert.equal((await t.deliver(data)).success, true);
    assert.equal(t.order().status, 'delivered');
    assert.equal(t.order().deliveryPhoto, undefined);
    assert.deepEqual(t.probes, []);
  }
});

test('commande déjà livrée (rejeu) : le comportement existant est conservé, la photo déjà enregistrée n est pas modifiée', async () => {
  const t = setup();
  await t.deliver({ deliveryPhotoUrl: GOOD });
  await assert.rejects(t.deliver({ deliveryPhotoUrl: GOOD }), code('failed-precondition'));
  assert.equal(t.order().deliveryPhoto, GOOD);
});

test('livreur non assigné : refusé ; la photo d un autre livreur ne sert à rien', async () => {
  const t = setup({ files: ['delivery_photos/dB/o1.jpg'] });
  await assert.rejects(t.deliver({ deliveryPhotoUrl: urlOf('delivery_photos/dB/o1.jpg') }, 'dB'), code('permission-denied'));
  await assert.rejects(t.deliver({ deliveryPhotoUrl: urlOf('delivery_photos/dB/o1.jpg') }, 'dA'), code('invalid-argument'));
  untouched(t);
});

test('sans contrôle injecté (tests unitaires historiques) : ancien comportement ; le câblage de production est testé plus bas', async () => {
  const t = setup({ check: false });
  await t.deliver({ deliveryPhotoUrl: 'https://x/p.jpg' });
  assert.equal(t.order().deliveryPhoto, 'https://x/p.jpg');
});

// ── confirmation administrative ──────────────────────────────────────────────────────────────────────────────────

test('confirmation par le super-administrateur : la photo éventuelle est celle du livreur de la commande, pas celle de l administrateur', async () => {
  const bad = setup({ adminConfirm: true, files: ['delivery_photos/root/o1.jpg'] });
  await assert.rejects(bad.adminConfirm({ deliveryPhotoUrl: urlOf('delivery_photos/root/o1.jpg') }), code('invalid-argument'));
  untouched(bad);
  const ok = setup({ adminConfirm: true });
  assert.equal((await ok.adminConfirm({ deliveryPhotoUrl: GOOD })).success, true);
  assert.equal(ok.order().deliveryPhoto, GOOD);
  const none = setup({ adminConfirm: true, files: [] });
  assert.equal((await none.adminConfirm({})).success, true);
});

// ── Câblage ──────────────────────────────────────────────────────────────────────────────────────────────────────

test('index.js injecte le contrôle dans les TROIS fonctions de livraison (sinon la validation serait muette en production)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  for (const name of ['deliverOrderCF', 'adminConfirmDeliveryCF', 'confirmOrderDeliveryWithProof']) {
    const at = src.indexOf(`exports.${name}`);
    assert.ok(at >= 0, name);
    const next = src.indexOf('\nexports.', at + 10);
    assert.match(src.slice(at, next), /deliveryPhotoCheck/, name);
  }
  assert.match(src, /exists: async \(path\) => \(await admin\.storage\(\)\.bucket\(\)\.file\(path\)\.exists\(\)\)\[0\]/);
});
