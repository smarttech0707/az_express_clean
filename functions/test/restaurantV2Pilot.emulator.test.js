'use strict';

// Mission 7E-36 — répétition LOCALE complète du lot de test Restaurant v2 contre l'émulateur Firestore (jamais le cloud) :
// préparation du lot, parcours complet avec les VRAIS modules de functions/, inventaire et nettoyage. Comptes Auth et Storage
// simulés en mémoire. Données fictives uniquement.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-t7e \
//     "node --test functions/test/restaurantV2Pilot.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Projet dédié : ce test vide toute la base de l’émulateur pour ce projet (wipe), il ne doit jamais viser les données d’un autre projet.
const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && process.env.GCLOUD_PROJECT === 'demo-az-t7e';
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-az-t7e)' };
const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const guard = require(path.join(dir, 'guard'));
const prepare = require(path.join(dir, 'prepare'));
const cleanup = require(path.join(dir, 'cleanup'));

const NOW = Date.UTC(2026, 10, 6, 10, 0, 0); // tarif de jour : frais 500 FCFA, commission 100 FCFA
const { client: CLIENT, restaurant: RESTO, driver: DRIVER, admin: ADMIN } = Object.fromEntries(Object.entries(lot.IDENTITIES).map(([k, v]) => [k, v.uid]));
const BUCKET = 'demo-bucket';

let admin; let db; let run; let auth; let bucketFiles; let bucket; let outDir; let manifest;

const asUser = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });

function fakeAuth() {
  const users = new Map();
  const notFound = () => Object.assign(new Error('user-not-found'), { code: 'auth/user-not-found' });
  return {
    users,
    getUser: async (uid) => { if (!users.has(uid)) throw notFound(); return users.get(uid); },
    getUserByEmail: async (email) => { const u = [...users.values()].find((x) => x.email === email); if (!u) throw notFound(); return u; },
    createUser: async (p) => { if (users.has(p.uid)) throw new Error('uid-already-exists'); const rec = { uid: p.uid, email: p.email, displayName: p.displayName }; users.set(p.uid, rec); return rec; },
    deleteUser: async (uid) => { users.delete(uid); },
  };
}
function fakeBucket(files) {
  return { file: (p) => ({ exists: async () => [files.has(p)], delete: async () => { files.delete(p); } }) };
}
async function wipe() {
  const res = await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${process.env.GCLOUD_PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  assert.equal(res.status, 200);
}
async function dumpAll() {
  const out = {};
  const walk = async (col) => {
    for (const d of (await col.get()).docs) { out[d.ref.path] = JSON.stringify(d.data()); for (const sub of await d.ref.listCollections()) await walk(sub); }
  };
  for (const c of await db.listCollections()) await walk(c);
  return out;
}
const only = (dump, test) => Object.fromEntries(Object.entries(dump).filter(([k]) => test(k)));
const wallets = async () => ({
  client: (await db.doc(`clients/${CLIENT}`).get()).data().wallet,
  driver: (await db.doc(`livreurs/${DRIVER}`).get()).data().wallet,
  restaurant: (await db.doc(`restaurants/${RESTO}`).get()).data().wallet,
});

async function seedHistoric() {
  await db.doc('zones_livraison/abengourou-test').set({
    type: 'ville', name: 'Abengourou (test)', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 8,
  });
  for (const id of ['hist-1', 'hist-2', 'hist-3']) {
    await db.doc(`orders/${id}`).set({ clientId: 'real-client', sellerId: 'real-resto', driverId: 'real-driver', status: 'delivered', totalAmount: 3000 });
  }
  await db.doc('clients/real-client').set({ name: 'Client existant', wallet: 12345, fcmToken: 'PLACEHOLDER-NOT-A-REAL-TOKEN' });
  await db.doc('livreurs/real-driver').set({ name: 'Livreur existant', wallet: 999, fcmToken: 'PLACEHOLDER-NOT-A-REAL-TOKEN-2', isOnline: true });
  await db.doc('restaurants/real-resto').set({ name: 'Resto existant', wallet: 5000, lat: 6.7, lng: -3.5 });
  await db.doc('audit_logs/a1').set({ action: 'historique' });
  await db.doc('rate_limits/real-client_quote').set({ requests: [1] });
  bucketFiles.add('acceptance_selfies/hist-1/real-driver.jpg');
}
const isHistoric = (p) => /^(orders\/hist-|clients\/real-|livreurs\/real-|restaurants\/real-|audit_logs\/|rate_limits\/real-)/.test(p);

test.before(async () => {
  if (!emulated) return;
  process.env.DELIVERY_PROOFS_ENABLED = 'true';
  process.env.DELIVERY_PROOF_PEPPER = 'emulator-test-only-pepper-not-a-secret';
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  auth = fakeAuth();
  bucketFiles = new Set();
  bucket = fakeBucket(bucketFiles);
  outDir = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-out-'));

  const { HttpsError } = require('firebase-functions/v2/https');
  const { dispatchOrder, calculateCommission } = require('../dispatch');
  const { dispatchAcceptedPartnerOrder } = require('../partnerDispatch');
  const { requireSuperAdmin } = require('../adminGuards');
  const { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF } = require('../partnerOrderQuote');
  const { buildPartnerOrderAction } = require('../partnerOrderActions');
  const { buildAcceptOrder } = require('../driverAcceptance');
  const { buildCancelOrder, buildDeliverOrderWithProof } = require('../orderActions');
  const proofs = require('../deliveryProofs');
  const base = {
    db, admin, onCall: (...a) => ({ run: a[a.length - 1] }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {},
    isEnabled: () => true,
  };
  const withProof = { ...base, deliveryProofPepper: { name: 'DELIVERY_PROOF_PEPPER' } };
  run = {
    quote: buildQuotePartnerOrderCF({ ...base, now: () => NOW }).run,
    create: buildCreatePartnerOrderFromQuoteCF({ ...base, now: () => NOW }).run,
    action: buildPartnerOrderAction({
      ...base, calculateCommission, requireSuperAdmin,
      dispatchAccepted: (orderId) => dispatchAcceptedPartnerOrder({ db, admin, dispatchOrder, orderId }),
    }).run,
    accept: buildAcceptOrder({ ...base, calculateCommission, selfieExists: async (p) => bucketFiles.has(p), selfieBucketName: () => BUCKET }).run,
    cancel: buildCancelOrder({ ...base, calculateCommission }).run,
    prepareProof: proofs.buildPrepareOrderProof(withProof).run,
    pickup: proofs.buildConfirmPickupWithProof(withProof).run,
    deliver: buildDeliverOrderWithProof({ ...withProof, calculateCommission }).run,
  };
});

// ── Aides de parcours ───────────────────────────────────────────────────────────────────────────────────────────────────────────
const request = () => ({ sellerType: 'restaurant', sellerId: RESTO, items: lot.BASKET, destination: lot.DELIVERY_POINT });
async function openPilot() {
  const res = await run.action(asUser(ADMIN, lot.pilotConfigPlan().request));
  assert.equal(res.success, true, JSON.stringify(res));
}
async function placeOrder() {
  const quote = await run.quote(asUser(CLIENT, request()));
  assert.equal(quote.success, true, JSON.stringify(quote));
  const order = await run.create(asUser(CLIENT, {
    ...request(), quoteId: quote.data.quoteId, paymentMethod: 'wallet', confirmedAmount: quote.data.total, deliveryAddress: 'Adresse fictive',
  }));
  assert.equal(order.success, true, JSON.stringify(order));
  return { orderId: order.data.orderId, total: quote.data.total, quoteId: quote.data.quoteId };
}
const partnerAction = async (orderId, action) => {
  const res = await run.action(asUser(RESTO, { orderId, action }));
  assert.equal(res.success, true, `${action} : ${JSON.stringify(res)}`);
  return res;
};
async function driverAccepts(orderId) {
  const p = `acceptance_selfies/${orderId}/${DRIVER}.jpg`;
  bucketFiles.add(p); // le livreur dépose son selfie (Storage) avant d’accepter
  const url = `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/${encodeURIComponent(p)}?alt=media&token=t`;
  return run.accept(asUser(DRIVER, { orderId, acceptanceSelfieUrl: url }));
}
const order = async (id) => (await db.doc(`orders/${id}`).get()).data();

test('1. collision : un document ou un compte déjà présent bloque TOUT, aucune écriture', options, async () => {
  await wipe();
  await seedHistoric();
  await db.doc(`clients/${CLIENT}`).set({ name: 'Déjà là', wallet: 1 });
  const before = await dumpAll();
  const a1 = fakeAuth();
  await assert.rejects(prepare.executePrepare({ admin, db, auth: a1, outDir: path.join(outDir, 'c1') }), (e) => e.code === 'COLLISION' && e.collisions.some((c) => c.id === `clients/${CLIENT}`));
  assert.equal(a1.users.size, 0);
  assert.deepEqual(await dumpAll(), before, 'aucune écriture Firestore');
  assert.ok(!fs.existsSync(path.join(outDir, 'c1', 'credentials.json')), 'aucun identifiant écrit');

  await db.doc(`clients/${CLIENT}`).delete();
  const a2 = fakeAuth();
  a2.users.set(ADMIN, { uid: ADMIN, email: 'admin-existant@example.invalid' }); // compte déjà présent sous cet uid
  await assert.rejects(prepare.executePrepare({ admin, db, auth: a2, outDir: path.join(outDir, 'c2') }), (e) => e.code === 'COLLISION' && e.collisions.some((c) => c.type === 'auth'));
  assert.equal(a2.users.size, 1);
  assert.equal((await db.doc(`restaurants/${RESTO}`).get()).exists, false);
});

test('2. préparation : exactement l’inventaire prévu, rien d’autre, données existantes intactes', options, async () => {
  await wipe();
  bucketFiles.clear();
  await seedHistoric();
  const historicBefore = only(await dumpAll(), isHistoric);
  manifest = await prepare.executePrepare({ admin, db, auth, outDir });

  assert.equal(manifest.status, 'complete');
  assert.deepEqual([...manifest.authUids].sort(), [...lot.UIDS].sort());
  assert.deepEqual([...auth.users.keys()].sort(), [...lot.UIDS].sort(), 'uid Auth = uid prévu (retrouvable dans le manifeste)');
  assert.deepEqual(manifest.baseline.orderIds, ['hist-1', 'hist-2', 'hist-3']);

  const after = await dumpAll();
  const created = Object.keys(after).filter((p) => !isHistoric(p) && p !== 'zones_livraison/abengourou-test').sort();
  assert.deepEqual(created, lot.buildSeedPlan().map((d) => d.path).sort(), 'seuls les documents du plan ont été créés');
  assert.deepEqual(only(after, isHistoric), historicBefore, 'données historiques identiques');
  assert.equal((await db.doc('config/partnerOrdersV2').get()).exists, false, 'pilote non créé');
  for (const p of created) assert.ok(!/fcm|token|phone|password/i.test(Object.keys(JSON.parse(after[p])).join()), p);
  const driver = (await db.doc(`livreurs/${DRIVER}`).get()).data();
  assert.ok(driver.updatedAt && typeof driver.updatedAt.toMillis === 'function', 'GPS horodaté par le serveur');

  const creds = JSON.parse(fs.readFileSync(path.join(outDir, 'credentials.json'), 'utf8'));
  assert.deepEqual(Object.keys(creds).sort(), ['admin', 'client', 'driver', 'restaurant']);
  for (const c of Object.values(creds)) { assert.ok(c.password.length >= 20); assert.ok(c.email.endsWith('@example.invalid')); }
  const manifestText = fs.readFileSync(path.join(outDir, 'manifest.json'), 'utf8');
  for (const c of Object.values(creds)) assert.ok(!manifestText.includes(c.password), 'aucun mot de passe dans le manifeste');
  await assert.rejects(prepare.executePrepare({ admin, db, auth, outDir }), (e) => e.code === 'COLLISION', 'relancer ne réécrit rien');
});

test('3. parcours complet : pilote, devis, commande, restaurant, livreur, QR/PIN, livraison — soldes exacts', options, async () => {
  const amounts = lot.expectedAmounts({ nowMs: NOW });
  const ledger = lot.expectedLedger(amounts);
  assert.deepEqual(await wallets(), ledger.start);

  // Pilote fermé par défaut : ni devis ni commande.
  const closed = await run.quote(asUser(CLIENT, request()));
  assert.equal(closed.success, false);
  assert.equal(closed.error, 'PARTNER_NOT_IN_PILOT');
  // Ouverture limitée au seul restaurant du lot, document conforme au plan.
  await openPilot();
  const cfg = (await db.doc('config/partnerOrdersV2').get()).data();
  const expected = lot.pilotConfigPlan().expectedDocument;
  assert.deepEqual({ pilotPartnerIds: cfg.pilotPartnerIds, creationOpen: cfg.creationOpen, managementFrozen: cfg.managementFrozen, version: cfg.version }, expected);
  // Un autre partenaire reste refusé.
  const other = await run.quote(asUser(CLIENT, { ...request(), sellerId: 'real-resto' }));
  assert.equal(other.success, false);
  assert.equal(other.error, 'PARTNER_NOT_IN_PILOT');

  // Devis et création : le client est débité du total exact, une seule fois.
  const quote = await run.quote(asUser(CLIENT, request()));
  assert.equal(quote.data.total, amounts.totalAmount);
  const created = await run.create(asUser(CLIENT, { ...request(), quoteId: quote.data.quoteId, paymentMethod: 'wallet', confirmedAmount: quote.data.total, deliveryAddress: 'Adresse fictive' }));
  assert.equal(created.success, true, JSON.stringify(created));
  const orderId = created.data.orderId;
  assert.deepEqual(await wallets(), ledger.afterCreate);
  const replay = await run.create(asUser(CLIENT, { ...request(), quoteId: quote.data.quoteId, paymentMethod: 'wallet', confirmedAmount: quote.data.total, deliveryAddress: 'Adresse fictive' }));
  assert.equal(replay.data.replayed, true);
  assert.deepEqual(await wallets(), ledger.afterCreate, 'rejeu : aucun second débit');
  const o1 = await order(orderId);
  assert.deepEqual([o1.amountsVersion, o1.productAmount, o1.deliveryFee, o1.totalAmount, o1.status, o1.sellerId, o1.clientId], [2, 6500, 500, 7000, 'pending', RESTO, CLIENT]);

  // Restaurant : acceptation (le dispatch propose la course au livreur du lot), préparation, prête.
  const accepted = await partnerAction(orderId, 'acceptPartnerOrder');
  assert.equal(accepted.data.dispatch.dispatched, true, `dispatch : ${JSON.stringify(accepted.data.dispatch)}`);
  const o2 = await order(orderId);
  // Un seul livreur éligible : le dispatch l’assigne directement (statut assigned) au lieu de diffuser l’offre (broadcast).
  assert.equal(o2.status, 'assigned');
  assert.equal(o2.driverId, DRIVER);
  await partnerAction(orderId, 'startPreparation');
  await partnerAction(orderId, 'markReady');

  // Livreur : commission prélevée une seule fois, même en cas de rejeu.
  assert.equal((await driverAccepts(orderId)).success, true);
  assert.deepEqual(await wallets(), ledger.afterAccept);
  assert.equal((await driverAccepts(orderId)).alreadyAccepted, true);
  assert.deepEqual(await wallets(), ledger.afterAccept, 'rejeu : pas de seconde commission');
  const o3 = await order(orderId);
  assert.deepEqual([o3.status, o3.driverId, o3.commissionAmount, o3.commissionPayerId], ['accepted', DRIVER, amounts.commission, DRIVER]);

  // Preuve de récupération : émise par le restaurant, confirmée par le livreur.
  await assert.rejects(run.prepareProof(asUser(CLIENT, { orderId, type: 'pickup' })), (e) => e.code === 'failed-precondition' || e.code === 'permission-denied');
  const pickup = await run.prepareProof(asUser(RESTO, { orderId, type: 'pickup' }));
  assert.equal(pickup.success, true);
  assert.match(pickup.pin, /^\d{6}$/);
  await run.pickup(asUser(DRIVER, { orderId, pin: pickup.pin }));
  assert.equal((await order(orderId)).status, 'picked_up');
  await assert.rejects(run.pickup(asUser(DRIVER, { orderId, pin: pickup.pin })), (e) => e.code === 'failed-precondition', 'code déjà utilisé');

  // Preuve de livraison : émise par le client, confirmée par le livreur → crédits en UNE transaction.
  const delivery = await run.prepareProof(asUser(CLIENT, { orderId, type: 'delivery' }));
  await assert.rejects(run.deliver(asUser(DRIVER, { orderId, proofPin: '000000' })), (e) => e.code === 'failed-precondition' || e.code === 'invalid-argument' || e.code === 'permission-denied');
  assert.deepEqual(await wallets(), ledger.afterAccept, 'mauvais code : aucun crédit');
  await run.deliver(asUser(DRIVER, { orderId, proofToken: delivery.token }));
  assert.equal((await order(orderId)).status, 'delivered');
  assert.deepEqual(await wallets(), ledger.afterDelivery);

  // Journaux : une écriture par mouvement, identifiants déterministes.
  const tx = async (p) => (await db.doc(p).get()).data();
  assert.equal((await tx(`clients/${CLIENT}/wallet_transactions/order_${orderId}`)).amount, amounts.totalAmount);
  assert.equal((await tx(`livreurs/${DRIVER}/wallet_transactions/commission_${orderId}_${DRIVER}`)).amount, amounts.commission);
  assert.equal((await tx(`restaurants/${RESTO}/wallet_transactions/earning_${orderId}`)).amount, amounts.productAmount);
  assert.equal((await tx(`livreurs/${DRIVER}/wallet_transactions/earning_${orderId}`)).amount, amounts.deliveryFee);
  const commissions = (await db.collection('commissions').where('orderId', '==', orderId).get()).size;
  assert.equal(commissions, 1, 'exactement une écriture de commission dans le journal');

  // Rejeu de la livraison : refusé, soldes inchangés.
  await assert.rejects(run.deliver(asUser(DRIVER, { orderId, proofToken: delivery.token })), (e) => e.code === 'failed-precondition');
  assert.deepEqual(await wallets(), ledger.afterDelivery);
});

test('4. annulations : refus du restaurant avant acceptation du livreur, après acceptation, annulation client — remboursements exacts', options, async () => {
  const amounts = lot.expectedAmounts({ nowMs: NOW });
  const start = await wallets();

  // A. Annulation par le client avant que le restaurant n’accepte : remboursement du total, idempotent.
  const a = await placeOrder();
  assert.equal((await wallets()).client, start.client - amounts.totalAmount);
  const cancelled = await run.cancel(asUser(CLIENT, { orderId: a.orderId }));
  assert.ok(cancelled.success !== false, JSON.stringify(cancelled));
  assert.equal((await order(a.orderId)).status, 'cancelled');
  assert.deepEqual(await wallets(), start, 'remboursement intégral');
  await run.cancel(asUser(CLIENT, { orderId: a.orderId })).catch(() => {});
  assert.deepEqual(await wallets(), start, 'double annulation : aucun second remboursement');

  // B. Refus du restaurant avant toute acceptation : remboursement intégral.
  const b = await placeOrder();
  await partnerAction(b.orderId, 'refusePartnerOrder');
  assert.equal((await order(b.orderId)).status, 'cancelled');
  assert.deepEqual(await wallets(), start);

  // C. Livreur accepté (commission prélevée), puis refus du restaurant avant préparation : client remboursé et commission rendue.
  await prepare.refreshDriverGps({ admin, db });
  const c = await placeOrder();
  await partnerAction(c.orderId, 'acceptPartnerOrder');
  assert.equal((await driverAccepts(c.orderId)).success, true);
  assert.equal((await wallets()).driver, start.driver - amounts.commission);
  await partnerAction(c.orderId, 'refusePartnerOrder');
  assert.equal((await order(c.orderId)).status, 'cancelled');
  assert.deepEqual(await wallets(), start, 'client remboursé du total, commission rendue au livreur payeur');
  assert.equal((await db.doc(`livreurs/${DRIVER}`).get()).data().isOnDelivery, false, 'livreur libéré');

  // D. Solde insuffisant : aucun débit partiel, aucune commande.
  await db.doc(`clients/${CLIENT}`).update({ wallet: amounts.totalAmount - 1 });
  const quote = await run.quote(asUser(CLIENT, request()));
  const poor = await run.create(asUser(CLIENT, { ...request(), quoteId: quote.data.quoteId, paymentMethod: 'wallet', confirmedAmount: quote.data.total, deliveryAddress: 'Adresse fictive' }));
  assert.equal(poor.success, false);
  assert.equal((await wallets()).client, amounts.totalAmount - 1);
  await db.doc(`clients/${CLIENT}`).update({ wallet: start.client });
});

test('5. nettoyage en DRY-RUN : inventaire exact, aucune écriture, empreinte stable', options, async () => {
  const before = await dumpAll();
  const ctx = { admin, db, auth, bucket, manifest };
  const inv = await cleanup.collectInventory(ctx);
  assert.deepEqual(inv.conflicts, [], JSON.stringify(inv.conflicts));
  const report = cleanup.dryRun(inv);
  assert.equal(report.writes, 0);
  assert.equal(report.executable, true);
  assert.deepEqual(await dumpAll(), before, 'le dry-run n’écrit rien');
  assert.equal((await cleanup.collectInventory(ctx)).hash, inv.hash, 'empreinte déterministe');

  const paths = inv.items.map((i) => i.path || i.uid);
  // Tout ce qui appartient au lot y figure…
  for (const p of lot.buildSeedPlan().map((d) => d.path)) assert.ok(paths.includes(p), p);
  for (const uid of lot.UIDS) assert.ok(paths.includes(uid), uid);
  assert.ok(paths.includes('config/partnerOrdersV2'));
  assert.equal(inv.lotOrderIds.length, 4);
  assert.ok(inv.items.some((i) => i.group === 'proof') && inv.items.some((i) => i.group === 'ledger') && inv.items.some((i) => i.group === 'quote'));
  assert.equal(inv.items.filter((i) => i.type === 'storage').length, 2, 'selfies des deux commandes acceptées');
  // … et rien d’historique, aucun compte existant.
  assert.ok(!paths.some((p) => /hist-|real-|audit_logs|rate_limits|abengourou/.test(p)));
  assert.ok(!paths.some((p) => /^orders\//.test(p) && !inv.lotOrderIds.includes(p.split('/')[1])));
});

test('6. nettoyage : conflits et références croisées bloquent tout, rien n’est supprimé', options, async () => {
  const ctx = { admin, db, auth, bucket, manifest };
  const good = await cleanup.collectInventory(ctx);
  const confirm = guard.confirmationFor('DELETE');
  const refuses = async (label, code, mutate, revert, reason) => {
    await mutate();
    try {
      const before = await dumpAll();
      const inv = await cleanup.collectInventory(ctx);
      assert.ok(inv.conflicts.some((c) => reason.test(c.reason)), `${label} : conflit attendu, obtenu ${JSON.stringify(inv.conflicts)}`);
      await assert.rejects(cleanup.executeCleanup({ ...ctx, expectedHash: inv.hash, confirm }), (e) => e.code === code, label);
      assert.deepEqual(await dumpAll(), before, `${label} : rien n’a été supprimé ni modifié`);
      assert.equal(auth.users.size, 4);
    } finally { await revert(); }
  };

  await refuses('commande liée à un autre compte', 'CONFLICTS',
    () => db.doc('orders/foreign-1').set({ clientId: CLIENT, sellerId: 'real-resto', status: 'delivered' }),
    () => db.doc('orders/foreign-1').delete(), /autre compte/);
  await refuses('commande du lot non terminée', 'CONFLICTS',
    () => db.doc('orders/active-1').set({ clientId: CLIENT, sellerId: RESTO, status: 'pending' }),
    () => db.doc('orders/active-1').delete(), /non terminée/);
  const hist1 = (await db.doc('orders/hist-1').get()).data();
  await refuses('commande historique protégée', 'CONFLICTS',
    () => db.doc('orders/hist-1').update({ clientId: CLIENT, sellerId: RESTO }),
    () => db.doc('orders/hist-1').set(hist1), /historique protégée/);
  const pilot = (await db.doc('config/partnerOrdersV2').get()).data();
  await refuses('pilote désignant d’autres partenaires', 'CONFLICTS',
    () => db.doc('config/partnerOrdersV2').update({ pilotPartnerIds: [RESTO, 'real-resto'] }),
    () => db.doc('config/partnerOrdersV2').set(pilot), /autres partenaires/);
  await refuses('jeton FCM sur un document du lot', 'CONFLICTS',
    () => db.doc(`clients/${CLIENT}`).update({ fcmToken: 'PLACEHOLDER' }),
    () => db.doc(`clients/${CLIENT}`).update({ fcmToken: admin.firestore.FieldValue.delete() }), /sensible/);
  await refuses('écriture de wallet sans commande du lot', 'CONFLICTS',
    () => db.doc(`clients/${CLIENT}/wallet_transactions/manuel-1`).set({ type: 'recharge', amount: 1 }),
    () => db.doc(`clients/${CLIENT}/wallet_transactions/manuel-1`).delete(), /sans commande du lot/);
  await refuses('document du manifeste sans marqueur du lot', 'CONFLICTS',
    () => db.doc(`livreurs/${DRIVER}`).update({ [lot.LOT_FIELD]: admin.firestore.FieldValue.delete() }),
    () => db.doc(`livreurs/${DRIVER}`).update({ [lot.LOT_FIELD]: lot.LOT_ID }), /sans marqueur/);
  const email = auth.users.get(ADMIN).email;
  await refuses('compte Auth dont l’e-mail diffère', 'CONFLICTS',
    async () => { auth.users.get(ADMIN).email = 'intrus@example.org'; },
    async () => { auth.users.get(ADMIN).email = email; }, /ne correspondant pas/);

  // Confirmation et empreinte.
  await assert.rejects(cleanup.executeCleanup({ ...ctx, expectedHash: good.hash, confirm: 'DELETE' }), (e) => e.code === 'CONFIRMATION_REQUIRED');
  await assert.rejects(cleanup.executeCleanup({ ...ctx, expectedHash: undefined, confirm }), (e) => e.code === 'INVENTORY_CHANGED');
  await assert.rejects(cleanup.executeCleanup({ ...ctx, expectedHash: 'f'.repeat(64), confirm }), (e) => e.code === 'INVENTORY_CHANGED');
  assert.equal((await cleanup.collectInventory(ctx)).hash, good.hash, 'état rétabli');
});

test('7. nettoyage exécuté : pilote fermé d’abord, lot supprimé, ressources non inventoriées et historiques intactes', options, async () => {
  // Pièges : mêmes préfixes t7e- mais hors inventaire, données historiques, jeton FCM existant.
  await db.doc('clients/t7e-intrus').set({ name: 'Préfixe sans appartenance au lot', wallet: 7 });
  await db.doc('orders/t7e-intrus-order').set({ clientId: 'real-client', sellerId: 'real-resto', status: 'delivered' });
  await db.doc('audit_logs/a2').set({ action: 'trace du lot (conservée)', targetId: 'x' });
  const protectedBefore = only(await dumpAll(), (p) => isHistoric(p) || /t7e-intrus|audit_logs\/a2/.test(p));
  bucketFiles.add('acceptance_selfies/t7e-intrus-order/someone-else.jpg');

  const ops = [];
  const spied = new Proxy(db, { get: (t, k) => {
    if (k === 'doc') {
      return (p) => new Proxy(t.doc(p), { get: (r, m) => {
        if (m === 'update' || m === 'delete') return (...a) => { ops.push(`${m}:${p}`); return r[m](...a); };
        const v = r[m]; return typeof v === 'function' ? v.bind(r) : v;
      } });
    }
    const v = t[k]; return typeof v === 'function' ? v.bind(t) : v;
  } });
  const ctx = { admin, db: spied, auth, bucket, manifest };
  const inv = await cleanup.collectInventory(ctx);
  assert.deepEqual(inv.conflicts, []);
  const result = await cleanup.executeCleanup({ ...ctx, expectedHash: inv.hash, confirm: guard.confirmationFor('DELETE') });
  assert.equal(result.clean, true, JSON.stringify(result));
  assert.equal(result.remaining, 0);

  // Ordre : fermeture du pilote avant toute suppression, configuration supprimée en dernier, sous-documents avant leurs parents.
  assert.equal(ops[0], 'update:config/partnerOrdersV2');
  assert.equal(ops.filter((o) => o === 'delete:config/partnerOrdersV2').length, 1);
  const lastFirestoreDelete = ops.map((o, i) => [o, i]).filter(([o]) => o.startsWith('delete:')).pop()[0];
  assert.equal(lastFirestoreDelete, 'delete:config/partnerOrdersV2');
  const at = (o) => ops.indexOf(o);
  assert.ok(ops.filter((o) => /wallet_transactions/.test(o)).every((o) => at(o) < at(`delete:clients/${CLIENT}`) || !o.includes('/clients/')));
  assert.ok(ops.filter((o) => /\/versions\//.test(o)).every((o) => at(o) < ops.findIndex((x) => /delete:delivery_proofs\/[^/]+$/.test(x))));

  // État final : plus rien du lot, tout le reste identique.
  const after = await dumpAll();
  assert.deepEqual(Object.keys(after).filter((p) => /t7e-(client|resto|driver|admin|plat)/.test(p)), []);
  assert.equal(Object.keys(after).filter((p) => /^orders\//.test(p) && !isHistoric(p) && !/t7e-intrus/.test(p)).length, 0);
  assert.equal(auth.users.size, 0, 'comptes Auth fictifs supprimés');
  assert.deepEqual([...bucketFiles].sort(), ['acceptance_selfies/hist-1/real-driver.jpg', 'acceptance_selfies/t7e-intrus-order/someone-else.jpg']);
  assert.deepEqual(only(after, (p) => isHistoric(p) || /t7e-intrus|audit_logs\/a2/.test(p)), protectedBefore, 'historique, FCM existants, préfixes hors lot et audit : intacts');
  assert.equal(JSON.parse(after['clients/real-client']).fcmToken, 'PLACEHOLDER-NOT-A-REAL-TOKEN');

  // Rien à refaire : un second passage ne supprime plus rien.
  const again = await cleanup.collectInventory({ admin, db, auth, bucket, manifest });
  assert.equal(again.items.length, 0);
});

test('8. GPS du livreur : rafraîchi seulement pour le livreur du lot', options, async () => {
  await assert.rejects(prepare.refreshDriverGps({ admin, db }), (e) => e.code === 'NOT_IN_LOT', 'livreur supprimé : aucune écriture');
  await db.doc(`livreurs/${DRIVER}`).set({ wallet: 1, isOnline: false });
  await assert.rejects(prepare.refreshDriverGps({ admin, db }), (e) => e.code === 'NOT_IN_LOT', 'sans marqueur du lot');
  assert.equal((await db.doc(`livreurs/${DRIVER}`).get()).data().isOnline, false);
  await db.doc(`livreurs/${DRIVER}`).delete();
});
