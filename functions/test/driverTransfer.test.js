'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HttpsError } = require('firebase-functions/v2/https');
const { fakeDb, DELETE, arrayUnion } = require('./fakeFirestore');
const { buildDeliveryTransfer, MAX_TRANSFERS, expireTransfer, expireDueTransfers } = require('../driverTransfer');
const { sessionId, verifyProofInTransaction } = require('../deliveryProofs');

process.env.DELIVERY_PROOFS_ENABLED = 'true';
process.env.DELIVERY_PROOF_PEPPER = 'test-pepper';

const ts = (ms) => ({ toMillis: () => ms });
const admin = {
  firestore: {
    Timestamp: { fromMillis: ts },
    FieldValue: { serverTimestamp: () => 'ts', delete: () => DELETE, arrayUnion },
  },
};

const driver = (extra = {}) => ({
  wallet: 1000, isOnline: true, isAvailable: true, currentCityId: 'abengourou', lat: 6.73, lng: -3.49, ...extra,
});

function setup({ order = {}, extra = {}, notify } = {}) {
  const db = fakeDb({
    'orders/o1': {
      clientId: 'c1', driverId: 'dA', status: 'picked_up', budget: 1500, paymentMethod: 'cash',
      isPaid: false, pickupCityId: 'abengourou', deliveryProofMode: 'qr_v1',
      driverAssignmentVersion: 1, transferCount: 0,
      commissionStatus: 'charged', commissionPayerId: 'dA', commissionAmount: 200,
      commissionTxId: 'commission_o1_dA', ...order,
    },
    'livreurs/dA': driver({ isOnDelivery: true }),
    'livreurs/dB': driver(),
    'livreurs/dC': driver(),
    'livreurs/dFar': driver({ currentCityId: 'autre' }),
    'livreurs/dBusy': driver({ isOnDelivery: true }),
    'livreurs/dSusp': driver({ isSuspended: true }),
    ...extra,
  });
  const notified = [];
  const run = buildDeliveryTransfer({
    db, admin, onCall: (...args) => ({ run: args[args.length - 1] }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {},
    deliveryProofPepper: null, notify: notify || (async (n) => { notified.push(n); }),
  }).run;
  const req = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
  const call = (uid, data) => run(req(uid, data));
  return { db, call, notified };
}
const order = (h) => h.db.store.get('orders/o1');
const get = (h, p) => h.db.store.get(p);

async function toAccepted(h, accepter = 'dB') {
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'vehicle_problem' });
  await h.call(accepter, { action: 'accept', transferId: r.transferId });
  return r.transferId;
}
async function complete(h) {
  const id = await toAccepted(h);
  const p = await h.call('dB', { action: 'prepareHandover', transferId: id });
  const res = await h.call('dA', { action: 'confirmHandover', transferId: id, token: p.token });
  return { id, p, res };
}

test('demande après récupération : transfert créé, A reste responsable, candidats de la même ville seulement', async () => {
  const h = setup();
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'emergency' });
  assert.equal(r.success, true);
  const t = get(h, `delivery_transfers/${r.transferId}`);
  assert.equal(t.status, 'requested');
  assert.deepEqual([...t.candidateIds].sort(), ['dB', 'dC']);
  assert.equal(order(h).driverId, 'dA');
  assert.equal(order(h).activeTransferId, r.transferId);
  assert.equal(h.notified[0].event, 'transfer_requested');
});

test('refus : mauvais livreur, hors picked_up, motif invalide, budget d’achat, demande concurrente', async () => {
  const h = setup();
  await assert.rejects(h.call('dB', { action: 'request', orderId: 'o1', reason: 'other' }), { code: 'permission-denied' });
  await assert.rejects(h.call('dA', { action: 'request', orderId: 'o1', reason: 'zzz' }), { code: 'invalid-argument' });
  const h2 = setup({ order: { status: 'accepted' } });
  await assert.rejects(h2.call('dA', { action: 'request', orderId: 'o1', reason: 'other' }), { code: 'failed-precondition' });
  const h3 = setup({ order: { shoppingBudget: 500 } });
  await assert.rejects(h3.call('dA', { action: 'request', orderId: 'o1', reason: 'other' }), /SHOPPING_BUDGET_REVIEW/);
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  const again = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  assert.equal(again.replay, true);
  assert.equal(again.transferId, r.transferId);
});

test('aucun candidat disponible : refus clair', async () => {
  const h = setup({ extra: { 'livreurs/dB': driver({ isOnDelivery: true }), 'livreurs/dC': driver({ isSuspended: true }) } });
  await assert.rejects(h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' }), /Aucun livreur disponible/);
});

test('acceptation : livreur suspendu, occupé, autre ville, non candidat refusés', async () => {
  const h = setup();
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  for (const uid of ['dSusp', 'dBusy', 'dFar']) {
    await assert.rejects(h.call(uid, { action: 'accept', transferId: r.transferId }), { code: 'permission-denied' });
  }
  // un candidat devenu occupé entre-temps
  h.db.store.set('livreurs/dB', driver({ isOnDelivery: true }));
  await assert.rejects(h.call('dB', { action: 'accept', transferId: r.transferId }), { code: 'failed-precondition' });
  // le demandeur ne peut pas s’accepter lui-même
  await assert.rejects(h.call('dA', { action: 'accept', transferId: r.transferId }), { code: 'permission-denied' });
});

test('deux acceptations simultanées : une seule gagne', async () => {
  const h = setup();
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  await h.call('dB', { action: 'accept', transferId: r.transferId });
  await assert.rejects(h.call('dC', { action: 'accept', transferId: r.transferId }), { code: 'failed-precondition' });
  const t = get(h, `delivery_transfers/${r.transferId}`);
  assert.equal(t.toDriverId, 'dB');
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, true);
  assert.equal(get(h, 'livreurs/dC').isOnDelivery, undefined);
  // rejeu du gagnant : idempotent
  assert.equal((await h.call('dB', { action: 'accept', transferId: r.transferId })).replay, true);
});

test('expiration : une demande expirée ne peut plus être acceptée et un nouveau transfert la remplace', async () => {
  const h = setup();
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  get(h, `delivery_transfers/${r.transferId}`).expiresAtMs = Date.now() - 1;
  await assert.rejects(h.call('dB', { action: 'accept', transferId: r.transferId }), /expiré/);
  const r2 = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  assert.notEqual(r2.transferId, r.transferId);
  assert.equal(get(h, `delivery_transfers/${r.transferId}`).status, 'expired');
});

test('B se retire après acceptation : réservation levée, demande rouverte', async () => {
  const h = setup();
  const id = await toAccepted(h);
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, true);
  await h.call('dB', { action: 'decline', transferId: id });
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, false);
  assert.equal(get(h, 'livreurs/dB').pendingOrderId, undefined);
  const t = get(h, `delivery_transfers/${id}`);
  assert.equal(t.status, 'requested');
  assert.equal(t.toDriverId, null);
  await h.call('dC', { action: 'accept', transferId: id });
  assert.equal(get(h, `delivery_transfers/${id}`).toDriverId, 'dC');
});

test('tous les candidats refusent : transfert clos et verrou levé', async () => {
  const h = setup();
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  await h.call('dB', { action: 'decline', transferId: r.transferId });
  await h.call('dC', { action: 'decline', transferId: r.transferId });
  assert.equal(get(h, `delivery_transfers/${r.transferId}`).status, 'declined');
  assert.equal(order(h).activeTransferId, undefined);
});

test('annulation par A avant la remise : B libéré, A garde la course', async () => {
  const h = setup();
  const id = await toAccepted(h);
  await assert.rejects(h.call('dB', { action: 'cancel', transferId: id }), { code: 'permission-denied' });
  await h.call('dA', { action: 'cancel', transferId: id });
  assert.equal(get(h, `delivery_transfers/${id}`).status, 'cancelled');
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, false);
  assert.equal(order(h).driverId, 'dA');
  assert.equal(order(h).activeTransferId, undefined);
});

test('remise réussie par QR : B remplace A atomiquement, version incrémentée, historique, états livreurs', async () => {
  const h = setup();
  const { id, res } = await complete(h);
  assert.equal(res.newDriverId, 'dB');
  const o = order(h);
  assert.equal(o.driverId, 'dB');
  assert.equal(o.driverAssignmentVersion, 2);
  assert.equal(o.transferCount, 1);
  assert.equal(o.activeTransferId, undefined);
  assert.equal(o.status, 'picked_up');
  assert.equal(o.budget, 1500);
  assert.equal(o.clientId, 'c1');
  assert.equal(o.settlementHold, true);
  assert.equal(o.driverHistory[0].driverId, 'dA');
  assert.equal(o.driverHistory[0].handedOverTo, 'dB');
  assert.equal(get(h, 'livreurs/dA').isOnDelivery, false);
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, true);
  assert.equal(get(h, 'livreurs/dB').pendingOrderId, undefined);
  assert.equal(get(h, `delivery_transfers/${id}`).status, 'completed');
});

test('remise par PIN valide ; PIN erroné refusé et compté ; code QR invalide refusé', async () => {
  const h = setup();
  const id = await toAccepted(h);
  const p = await h.call('dB', { action: 'prepareHandover', transferId: id });
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, token: 'faux-code' }), /invalide/);
  const wrong = p.pin === '000000' ? '111111' : '000000';
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, pin: wrong }), /invalide/);
  const proofKey = [...h.db.store.keys()].find((k) => k.includes('/versions/'));
  assert.equal(h.db.store.get(proofKey).pinAttempts, 1);
  assert.equal(order(h).driverId, 'dA');
  const ok = await h.call('dA', { action: 'confirmHandover', transferId: id, pin: p.pin });
  assert.equal(ok.success, true);
  assert.equal(order(h).driverId, 'dB');
});

test('PIN : 5 essais faux verrouillent la preuve', async () => {
  const h = setup();
  const id = await toAccepted(h);
  const p = await h.call('dB', { action: 'prepareHandover', transferId: id });
  const wrong = p.pin === '000000' ? '111111' : '000000';
  for (let i = 0; i < 5; i++) {
    await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, pin: wrong }));
  }
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, pin: p.pin }), /tentatives/);
  assert.equal(order(h).driverId, 'dA');
});

test('preuve expirée refusée', async () => {
  const h = setup();
  const id = await toAccepted(h);
  const p = await h.call('dB', { action: 'prepareHandover', transferId: id });
  const proofKey = [...h.db.store.keys()].find((k) => k.includes('/versions/'));
  h.db.store.get(proofKey).expiresAt = ts(Date.now() - 1000);
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, token: p.token }), /expir/);
  assert.equal(order(h).driverId, 'dA');
});

test('preuve déjà consommée / double confirmation : rejeu inoffensif, aucun second échange', async () => {
  const h = setup();
  const { id, p } = await complete(h);
  const again = await h.call('dA', { action: 'confirmHandover', transferId: id, token: p.token });
  assert.equal(again.replay, true);
  assert.equal(order(h).driverAssignmentVersion, 2);
  assert.equal(order(h).transferCount, 1);
  // la preuve consommée ne peut pas servir sur une autre session
  await assert.rejects(h.call('dB', { action: 'confirmHandover', transferId: id, token: p.token }), { code: 'permission-denied' });
});

test('seul B (destinataire du transfert) émet la preuve ; seul A la confirme', async () => {
  const h = setup();
  const id = await toAccepted(h);
  await assert.rejects(h.call('dC', { action: 'prepareHandover', transferId: id }), { code: 'permission-denied' });
  await assert.rejects(h.call('dA', { action: 'prepareHandover', transferId: id }), { code: 'permission-denied' });
  const p = await h.call('dB', { action: 'prepareHandover', transferId: id });
  await assert.rejects(h.call('dB', { action: 'confirmHandover', transferId: id, token: p.token }), { code: 'permission-denied' });
  await assert.rejects(h.call('dC', { action: 'confirmHandover', transferId: id, token: p.token }), { code: 'permission-denied' });
});

test('sans acceptation de B, impossible d’émettre ou de confirmer', async () => {
  const h = setup();
  const r = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  await assert.rejects(h.call('dB', { action: 'prepareHandover', transferId: r.transferId }), { code: 'permission-denied' });
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: r.transferId, pin: '123456' }), { code: 'failed-precondition' });
});

test('limite de 2 transferts : un troisième est refusé', async () => {
  assert.equal(MAX_TRANSFERS, 2);
  const h = setup();
  await complete(h); // A -> B
  // B demande à son tour (C remplaçant)
  const r2 = await h.call('dB', { action: 'request', orderId: 'o1', reason: 'fatigue' });
  await h.call('dC', { action: 'accept', transferId: r2.transferId });
  const p2 = await h.call('dC', { action: 'prepareHandover', transferId: r2.transferId });
  await h.call('dB', { action: 'confirmHandover', transferId: r2.transferId, token: p2.token });
  assert.equal(order(h).driverId, 'dC');
  assert.equal(order(h).transferCount, 2);
  h.db.store.set('livreurs/dA', driver());
  await assert.rejects(h.call('dC', { action: 'request', orderId: 'o1', reason: 'other' }), { code: 'resource-exhausted' });
});

test('ancien livreur ne peut plus livrer ni demander de transfert ; nouveau livreur oui (version liée)', async () => {
  const h = setup();
  await complete(h);
  await assert.rejects(h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' }), { code: 'permission-denied' });
  // une preuve liée à A (version 1) n’est plus valide pour la version 2
  const result = await h.db.runTransaction((tx) => verifyProofInTransaction({
    tx, db: h.db, orderId: 'o1', type: 'delivery', driverId: 'dA', assignmentVersion: 2,
    token: 'x', pepper: 'p', now: Date.now(), admin,
  }));
  assert.equal(result.ok, false);
});

test('preuve de livraison active de A révoquée au changement de livreur', async () => {
  const h = setup();
  const sid = `delivery_proofs/${sessionId('o1', 'delivery')}`;
  h.db.store.set(sid, { currentProofId: 'pd1', driverId: 'dA', assignmentVersion: 1, generationCount: 1 });
  h.db.store.set(`${sid}/versions/pd1`, { status: 'active', driverId: 'dA', assignmentVersion: 1, expiresAt: ts(Date.now() + 60000) });
  await complete(h);
  assert.equal(h.db.store.get(`${sid}/versions/pd1`).status, 'revoked');
});

test('commission : aucun second prélèvement, aucun remboursement de A, aucun crédit à B', async () => {
  const h = setup();
  const walletsBefore = ['dA', 'dB', 'dC'].map((d) => get(h, `livreurs/${d}`).wallet);
  await complete(h);
  const o = order(h);
  assert.deepEqual([o.commissionStatus, o.commissionPayerId, o.commissionAmount, o.commissionTxId],
    ['charged', 'dA', 200, 'commission_o1_dA']);
  assert.deepEqual(['dA', 'dB', 'dC'].map((d) => get(h, `livreurs/${d}`).wallet), walletsBefore);
  assert.equal([...h.db.store.keys()].filter((k) => k.includes('wallet_transactions')).length, 0);
});

test('commande ordinaire sans transfert : aucun champ de transfert ajouté', async () => {
  const h = setup();
  const o = order(h);
  for (const f of ['activeTransferId', 'previousDriverId', 'settlementHold', 'transferAttempts']) {
    assert.equal(o[f], undefined);
  }
});

test('utilisateur anonyme et action inconnue refusés', async () => {
  const h = setup();
  const run = buildDeliveryTransfer({
    db: h.db, admin, onCall: (...a) => ({ run: a[a.length - 1] }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {},
  }).run;
  await assert.rejects(run({ auth: { uid: 'x', token: { firebase: { sign_in_provider: 'anonymous' } } }, data: {} }), { code: 'unauthenticated' });
  await assert.rejects(h.call('dA', { action: 'hack' }), { code: 'invalid-argument' });
});

test('flag DELIVERY_PROOFS_ENABLED désactivé : la remise est indisponible, rien ne change', async () => {
  const h = setup();
  const id = await toAccepted(h);
  process.env.DELIVERY_PROOFS_ENABLED = 'false';
  try {
    await assert.rejects(h.call('dB', { action: 'prepareHandover', transferId: id }), { code: 'failed-precondition' });
  } finally { process.env.DELIVERY_PROOFS_ENABLED = 'true'; }
});

test('transfert accepté mais remise non confirmée à temps : B libéré, A reste responsable, QR/PIN tardif refusé', async () => {
  const h = setup();
  const id = await toAccepted(h);
  const p = await h.call('dB', { action: 'prepareHandover', transferId: id });
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, true);
  get(h, `delivery_transfers/${id}`).expiresAtMs = Date.now() - 1;
  // validation tardive : refusée ET le transfert est clos dans la foulée
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, token: p.token }), /expiré/);
  const t = get(h, `delivery_transfers/${id}`);
  assert.equal(t.status, 'expired');
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, false);
  assert.equal(get(h, 'livreurs/dB').pendingOrderId, undefined);
  assert.equal(order(h).driverId, 'dA');
  assert.equal(order(h).activeTransferId, undefined);
  assert.equal(order(h).driverAssignmentVersion, 1);
  assert.equal(order(h).transferCount, 0);
  // le code reste inutilisable même si on tente de rouvrir : transfert expiré
  await assert.rejects(h.call('dA', { action: 'confirmHandover', transferId: id, pin: p.pin }), { code: 'failed-precondition' });
  // nouvelle recherche possible, avec un nouvel identifiant
  const again = await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' });
  assert.notEqual(again.transferId, id);
});

test('balayage planifié : libère B sans action des livreurs ; double expiration et concurrence sans effet double', async () => {
  const h = setup();
  const id = await toAccepted(h);
  get(h, `delivery_transfers/${id}`).expiresAtMs = Date.now() - 1;
  // Le faux Firestore ne sérialise pas les transactions : la concurrence réelle est
  // garantie par Firestore (relecture/réessai) ; ici on vérifie la double expiration.
  const r1 = await expireTransfer(h.db, admin, id);
  const r2 = await expireTransfer(h.db, admin, id);
  assert.deepEqual([r1, r2], [true, false]);
  assert.equal((await expireDueTransfers(h.db, admin)).expired, 0);
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, false);
  // transfert non échu : jamais expiré
  const id2 = (await h.call('dA', { action: 'request', orderId: 'o1', reason: 'other' })).transferId;
  assert.equal(await expireTransfer(h.db, admin, id2), false);
  assert.equal(get(h, `delivery_transfers/${id2}`).status, 'requested');
  // le balayage ferme aussi une demande échue non acceptée
  get(h, `delivery_transfers/${id2}`).expiresAtMs = Date.now() - 1;
  assert.equal((await expireDueTransfers(h.db, admin)).expired, 1);
  assert.equal(order(h).activeTransferId, undefined);
});

test('action expire : réservée aux acteurs du transfert', async () => {
  const h = setup();
  const id = await toAccepted(h);
  get(h, `delivery_transfers/${id}`).expiresAtMs = Date.now() - 1;
  await assert.rejects(h.call('dX', { action: 'expire', transferId: id }), { code: 'permission-denied' });
  assert.equal((await h.call('dB', { action: 'expire', transferId: id })).expired, true);
  assert.equal(get(h, 'livreurs/dB').isOnDelivery, false);
});

test('remise : positions GPS fraîches et proches enregistrées comme point fiable ; sinon non fiable', async () => {
  const fresh = () => ({ updatedAt: { toMillis: () => Date.now() - 1000 } });
  const h = setup({ extra: {
    'livreurs/dA': driver({ isOnDelivery: true, lat: 6.74, lng: -3.49, ...fresh() }),
    'livreurs/dB': driver({ lat: 6.7401, lng: -3.49, ...fresh() }),
  } });
  await complete(h);
  const hand = order(h).driverHistory[0].handover;
  assert.equal(hand.trusted, true);
  assert.ok(hand.separationM < 50);
  assert.ok(Math.abs(hand.point.lat - 6.74005) < 1e-6);
  // sans position fraîche : enregistrée comme non fiable (jamais inventée)
  const h2 = setup();
  await complete(h2);
  assert.equal(order(h2).driverHistory[0].handover.trusted, false);
  assert.equal(order(h2).driverHistory[0].handover.point, null);
});
