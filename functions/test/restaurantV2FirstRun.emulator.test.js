'use strict';

// Mission 7E-39 — répétition finale du premier parcours (S0 → S11) contre l'ÉMULATEUR Firestore uniquement (projet demo-az-t7e),
// avec les VRAIS modules métier et l'exécuteur par étapes runStep.js. Comptes Auth et Storage simulés en mémoire. Aucun accès cloud.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-t7e \
//     "node --test functions/test/restaurantV2FirstRun.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Le test vide la base de l'émulateur de CE projet : jamais un autre projet, jamais le cloud.
const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && process.env.GCLOUD_PROJECT === 'demo-az-t7e';
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-az-t7e)' };
const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const guard = require(path.join(dir, 'guard'));
const prepare = require(path.join(dir, 'prepare'));
const selfie = require(path.join(dir, 'selfie'));
const fr = require(path.join(dir, 'firstRun'));
const runner = require(path.join(dir, 'runStep'));

const NOW = Date.UTC(2026, 10, 6, 10, 0, 0); // jour : frais 500, total 7 000, commission 100
const NIGHT = Date.UTC(2026, 10, 6, 23, 0, 0);
const { client: CLIENT, restaurant: RESTO, driver: DRIVER, admin: ADMIN } = Object.fromEntries(Object.entries(lot.IDENTITIES).map(([k, v]) => [k, v.uid]));
const BUCKET = 'demo-bucket';
const MIN = 60 * 1000;

let admin; let db; let run; let bucketFiles; let manifest; let outDir; let io; let transcript;
const asUser = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });
const UID = { client: CLIENT, restaurant: RESTO, driver: DRIVER, admin: ADMIN };

function fakeAuth() {
  const users = new Map();
  const notFound = () => Object.assign(new Error('user-not-found'), { code: 'auth/user-not-found' });
  return {
    getUser: async (uid) => { if (!users.has(uid)) throw notFound(); return users.get(uid); },
    getUserByEmail: async (email) => { const u = [...users.values()].find((x) => x.email === email); if (!u) throw notFound(); return u; },
    createUser: async (p) => { const rec = { uid: p.uid, email: p.email, displayName: p.displayName }; users.set(p.uid, rec); return rec; },
    deleteUser: async (uid) => { users.delete(uid); },
  };
}
const memoryStore = () => {
  let saved = null;
  return { saved: () => saved, load: async () => (saved ? JSON.parse(saved) : { lotId: lot.LOT_ID, completed: [] }), save: async (s) => { saved = JSON.stringify(s); } };
};
const wallets = async () => ({
  client: (await db.doc(`clients/${CLIENT}`).get()).data().wallet,
  driver: (await db.doc(`livreurs/${DRIVER}`).get()).data().wallet,
  restaurant: (await db.doc(`restaurants/${RESTO}`).get()).data().wallet,
});
const order = async (id) => (await db.doc(`orders/${id}`).get()).data();
const setGpsAge = (ms) => db.doc(`livreurs/${DRIVER}`).update({ updatedAt: admin.firestore.Timestamp.fromMillis(Date.now() - ms) });
const choices = () => fr.choices();
// Un refus peut être une erreur (HttpsError) ou une enveloppe {success:false} : les deux sont des refus, jamais un succès.
const refused = async (promise, label) => {
  let res;
  try { res = await promise; } catch (_) { return; }
  assert.equal(res && res.success, false, `refus attendu : ${label || ''} ${JSON.stringify(res)}`);
};

test.before(async () => {
  if (!emulated) return;
  process.env.DELIVERY_PROOFS_ENABLED = 'true';
  process.env.DELIVERY_PROOF_PEPPER = 'emulator-test-only-pepper-not-a-secret';
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  bucketFiles = new Set();
  outDir = fs.mkdtempSync(path.join(os.tmpdir(), 't7e-first-run-'));

  // Aucune notification réelle : toute tentative d'accès à la messagerie fait échouer le test.
  Object.defineProperty(admin, 'messaging', { value: () => { throw new Error('FCM interdit dans ce test'); }, configurable: true });

  const { HttpsError } = require('firebase-functions/v2/https');
  const { dispatchOrder, calculateCommission } = require('../dispatch');
  const { dispatchAcceptedPartnerOrder } = require('../partnerDispatch');
  const { requireSuperAdmin } = require('../adminGuards');
  const { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF } = require('../partnerOrderQuote');
  const { buildPartnerOrderAction } = require('../partnerOrderActions');
  const { buildAcceptOrder } = require('../driverAcceptance');
  const { buildCancelOrder, buildDeliverOrderWithProof } = require('../orderActions');
  const proofs = require('../deliveryProofs');
  const base = { db, admin, onCall: (...a) => ({ run: a[a.length - 1] }), HttpsError, checkRateLimit: async () => {}, logAudit: async () => {}, isEnabled: () => true };
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
  const byFn = {
    [fr.FN.quote]: run.quote, [fr.FN.create]: run.create, [fr.FN.partner]: run.action, [fr.FN.accept]: run.accept,
    [fr.FN.prepareProof]: run.prepareProof, [fr.FN.pickup]: run.pickup, [fr.FN.deliver]: run.deliver,
  };
  transcript = [];
  // Même interface que cloudIo ; seuls les appels de fonctions sont simulés (modules réels, sans HTTP).
  io = {
    identity: async (role) => ({ uid: UID[role] }),
    call: async (fn, role, data) => {
      assert.ok(byFn[fn], `fonction hors parcours : ${fn}`); // dispatchOrderToDriver n'est jamais appelée
      const res = await byFn[fn](asUser(UID[role], data));
      transcript.push({ fn, role, data, res });
      return res;
    },
    read: async (p) => { const s = await db.doc(p).get(); return s.exists ? s.data() : null; },
    baselineOrderIds: async () => manifest.baseline.orderIds,
    refreshGps: () => prepare.refreshDriverGps({ admin, db }),
    uploadSelfie: async (up) => {
      assert.deepEqual(selfie.validateUpload({ objectPath: up.objectPath, contentType: up.contentType, size: up.size, uid: DRIVER }), [], 'règles Storage');
      bucketFiles.add(up.objectPath);
      return selfie.downloadUrl(up.objectPath, 'tok-demo', BUCKET);
    },
  };
});

async function seed() {
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${process.env.GCLOUD_PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  await db.doc('zones_livraison/abengourou-test').set({
    type: 'ville', name: 'Abengourou (test)', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 8,
  });
  for (const id of ['hist-1', 'hist-2']) await db.doc(`orders/${id}`).set({ clientId: 'real-client', sellerId: 'real-resto', driverId: 'real-driver', status: 'delivered', totalAmount: 3000 });
  await db.doc('clients/real-client').set({ name: 'Client existant', wallet: 12345, fcmToken: 'PLACEHOLDER-NOT-A-REAL-TOKEN' });
  await db.doc('restaurants/real-resto').set({ name: 'Resto existant', wallet: 5000, lat: 6.73, lng: -3.49, isOpen: true, isActive: true });
  await db.doc('restaurants/real-resto/menu/real-plat').set({ name: 'Plat', price: 1000, available: true });
}

async function runJourney(state, store, hooks = {}, nowMs = NOW) {
  const results = [];
  for (const id of runner.ORDER_OF_STEPS) {
    results.push(await runner.executeStep({ stepId: id, state, io, store, nowMs }));
    if (hooks[id]) await hooks[id]();
  }
  return results;
}

test('1. lot préparé sur l’émulateur ; production et ressources hors lot refusées avant tout accès', options, async () => {
  await seed();
  manifest = await prepare.executePrepare({ admin, db, auth: fakeAuth(), outDir });
  assert.equal(manifest.status, 'complete');

  for (const id of ['az-express-b0469', 'az-express-clean']) {
    assert.throws(() => guard.assertTarget({ projectId: id, projectNumber: '306761725053', env: {} }), (e) => e.code === 'PRODUCTION_FORBIDDEN');
  }
  assert.throws(() => guard.assertTarget({ projectId: 'az-express-preprod', projectNumber: '306761725053', env: { GCLOUD_PROJECT: 'az-express-b0469' } }), (e) => e.code === 'PRODUCTION_FORBIDDEN');
  assert.throws(() => guard.assertTarget({ projectId: 'az-express-preprod', projectNumber: '1', env: {} }), (e) => e.code === 'PROJECT_NUMBER_MISMATCH');
  assert.throws(() => guard.assertTarget({ projectId: 'az-express-preprod', projectNumber: '306761725053', env: { FIRESTORE_EMULATOR_HOST: 'x' } }), (e) => e.code === 'EMULATOR_ENV_WITH_REAL_PROJECT');

  // Ligne de commande : DRY-RUN sans réseau ; production, mauvaise confirmation et dossier dans le dépôt refusés.
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('réseau interdit en DRY-RUN'); };
  try {
    const lines = [];
    const base = ['--project', 'az-express-preprod', '--project-number', '306761725053', '--state-dir', path.join(outDir, 'state'), '--step', 'S1'];
    assert.equal(await runner.main(base, {}, (l) => lines.push(l)), 0);
    assert.match(lines.join('\n'), /DRY-RUN/);
    await assert.rejects(runner.main(['--project', 'az-express-b0469', '--project-number', '306761725053', '--state-dir', outDir, '--step', 'S1'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(runner.main([...base, '--execute', '--confirm', 'RUN S2 t7e-lot-1 az-express-preprod 306761725053'], {}, () => {}), (e) => e.code === 'CONFIRMATION_REQUIRED');
    await assert.rejects(runner.main(['--project', 'az-express-preprod', '--project-number', '306761725053', '--state-dir', path.join(guard.REPO_ROOT, 'tmp'), '--step', 'S1'], {}, () => {}), (e) => e.code === 'OUT_DIR_IN_REPO');
    await assert.rejects(runner.main([...base, '--force'], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT');
  } finally { globalThis.fetch = realFetch; }

  // Lectures et données hors lot refusées par le runner lui-même.
  const state = { baselineOrderIds: manifest.baseline.orderIds, orderId: 'ord-x', quoteId: 'q-x' };
  const read = runner.safeReader(io, state);
  for (const p of ['orders/hist-1', 'clients/real-client', 'restaurants/real-resto', 'orders/autre']) {
    await assert.rejects(read(p), (e) => e.code === 'OUT_OF_LOT' || e.code === 'HISTORIC_ORDER_REFUSED', p);
  }
  await assert.rejects(runner.safeReader(io, { ...state, orderId: 'hist-1' })('orders/hist-1'), (e) => e.code === 'HISTORIC_ORDER_REFUSED');
  assert.throws(() => runner.assertDataInLot({ sellerId: 'real-resto' }, state), (e) => e.code === 'OUT_OF_LOT');
  assert.throws(() => runner.assertDataInLot({ patch: { pilotPartnerIds: [RESTO, 'real-resto'] } }, state), (e) => e.code === 'OUT_OF_LOT');
  assert.throws(() => runner.assertDataInLot({ orderId: 'hist-1' }, state), (e) => e.code === 'OUT_OF_LOT');
  // La seule étape administrateur du parcours est S0, dont les données sont figées par le plan du lot.
  const adminSteps = fr.STEPS.filter((s) => s.caller === 'admin');
  assert.deepEqual(adminSteps.map((s) => s.id), ['S0']);
  assert.deepEqual(adminSteps[0].data(), lot.pilotConfigPlan().request);
  assert.deepEqual(adminSteps[0].data().patch.pilotClientIds, [CLIENT], 'S0 désigne explicitement le seul client fictif');
  assert.equal(adminSteps[0].data().patch.clientAccess, 'restricted');
  assert.throws(() => runner.assertDataInLot({ patch: { pilotClientIds: [CLIENT, 'real-client'] } }, state), (e) => e.code === 'OUT_OF_LOT');
  assert.throws(() => runner.assertDataInLot({ patch: { clientAccess: 'open' } }, state), (e) => e.code === 'OUT_OF_LOT', 'jamais d’ouverture générale par les scripts');
  assert.throws(() => runner.assertDataInLot({ confirmGeneralOpening: true }, state), (e) => e.code === 'OUT_OF_LOT');
});

test('2. parcours S0 → S11 par l’exécuteur : transitions, soldes, commission unique, pilote refermé', options, async () => {
  const store = memoryStore();
  const state = await store.load();
  const startWalletsDb = await wallets();
  assert.deepEqual(startWalletsDb, lot.WALLETS);

  // Fermé avant S0 : aucun devis.
  assert.equal((await run.quote(asUser(CLIENT, choices()))).error, 'PARTNER_NOT_IN_PILOT');

  const replayCreate = () => ({ ...choices(), quoteId: state.quoteId, paymentMethod: 'wallet', confirmedAmount: 7000, deliveryAddress: 'Adresse fictive de test, Abengourou' });
  const results = await runJourney(state, store, {
    S2: async () => { // double appui sur « commander » : même commande, aucun second débit
      assert.equal((await run.create(asUser(CLIENT, replayCreate()))).data.replayed, true);
      assert.equal((await wallets()).client, 33000);
    },
    S7: async () => { // rejeu de l'acceptation : aucune seconde commission
      assert.equal((await run.accept(asUser(DRIVER, { orderId: state.orderId, acceptanceSelfieUrl: state.selfieUrl }))).alreadyAccepted, true);
      assert.equal((await wallets()).driver, 4900);
    },
  });
  assert.deepEqual(state.completed, runner.ORDER_OF_STEPS);
  assert.equal(results.at(-1).next, null);
  assert.equal(state.total, 7000, 'devis de jour');
  assert.equal(state.quotedNight, false);
  const orderId = state.orderId;
  assert.ok(!manifest.baseline.orderIds.includes(orderId));

  // Transitions exactes et soldes finaux.
  const o = await order(orderId);
  assert.deepEqual([o.status, o.sellerStatus, o.driverId, o.clientId, o.sellerId, o.amountsVersion], ['delivered', 'ready', DRIVER, CLIENT, RESTO, 2]);
  assert.deepEqual([o.productAmount, o.deliveryFee, o.totalAmount, o.commissionAmount], [6500, 500, 7000, 100]);
  assert.deepEqual(await wallets(), { client: 33000, driver: 5400, restaurant: 6500 });
  assert.equal((await db.collection('commissions').where('orderId', '==', orderId).get()).size, 1);
  const stepsLog = results.map((r) => `${r.step}:${r.fn || r.caller}`);
  assert.equal(stepsLog.length, 13);
  assert.ok(!transcript.some((t) => t.fn === 'dispatchOrderToDriver'));
  assert.equal(bucketFiles.has(`acceptance_selfies/${orderId}/t7e-driver.jpg`), true);

  // Idempotence : rejeux sans second mouvement.
  await refused(run.accept(asUser(DRIVER, { orderId, acceptanceSelfieUrl: state.selfieUrl })), 'acceptation après livraison');
  await assert.rejects(run.pickup(asUser(DRIVER, { orderId, pin: state.secrets.pickup.pin })), (e) => e.code === 'failed-precondition', 'QR/PIN de récupération réutilisé');
  await assert.rejects(run.deliver(asUser(DRIVER, { orderId, proofToken: state.secrets.delivery.token })), (e) => e.code === 'failed-precondition', 'double livraison');
  await assert.rejects(run.deliver(asUser(DRIVER, { orderId, proofPin: state.secrets.delivery.pin })), (e) => ['failed-precondition', 'permission-denied'].includes(e.code), 'PIN de livraison réutilisé');
  assert.deepEqual(await wallets(), { client: 33000, driver: 5400, restaurant: 6500 }, 'aucun double crédit ni double commission');
  assert.equal((await db.collection('commissions').where('orderId', '==', orderId).get()).size, 1);

  // Aucun secret dans les sorties du runner ni dans l'état redacté.
  const secrets = [state.secrets.pickup.pin, state.secrets.pickup.token, state.secrets.delivery.pin, state.secrets.delivery.token];
  assert.ok(secrets.every(Boolean));
  const outputs = JSON.stringify(results) + JSON.stringify(runner.describeStep('S9', state)) + JSON.stringify(runner.describeStep('S11', state));
  for (const s of secrets) assert.ok(!outputs.includes(String(s)), 'secret visible dans une sortie');
  assert.equal(runner.redact(`erreur ${secrets[0]} ${secrets[1]} eyJhbGciOi.abc.def key=SECRET`, state).includes(secrets[0]), false);
  assert.ok(!/eyJ|key=SECRET/.test(runner.redact('x eyJhbGciOi.abc.def key=SECRET', state)));

  // Étape finale : fermeture d'urgence par le chemin audité, avec la version réellement lue (jamais supposée), sans suppression.
  assert.equal(state.configVersion, 1, 'version retournée par S0');
  const closed = await runner.closePilot({ state, io, store });
  assert.deepEqual([closed.closed, closed.version, closed.versionDivergedFromS0], [true, 2, false]);
  const cfg = (await db.doc('config/partnerOrdersV2').get()).data();
  assert.deepEqual([cfg.creationOpen, cfg.pilotPartnerIds, cfg.managementFrozen, cfg.version], [false, [RESTO], false, 2]);
  assert.equal(cfg.lastChange.by, ADMIN);
  assert.equal((await run.quote(asUser(CLIENT, choices()))).error, 'CREATION_CLOSED', 'pilote refermé');
  assert.equal((await runner.closePilot({ state, io, store })).alreadyClosed, true, 'fermeture idempotente');

  // Aucune notification : aucun document de déduplication, aucun accès à la messagerie.
  const collections = (await db.listCollections()).map((c) => c.id);
  assert.ok(!collections.some((c) => /notification|fcm/i.test(c)), collections.join());
  for (const f of ['partnerOrderActions.js', 'driverAcceptance.js', 'deliveryProofs.js', 'partnerDispatch.js', 'partnerOrderQuote.js']) {
    assert.ok(!/messaging\s*\(/.test(fs.readFileSync(path.join(__dirname, '..', f), 'utf8')), `${f} ne doit pas envoyer de FCM`);
  }
});

test('3. exécuteur : ordre imposé, aucune reprise, première erreur fige le parcours, secrets masqués', options, async () => {
  // Pilote réouvert (version 2 → 3) pour les essais suivants.
  const reopen = await run.action(asUser(ADMIN, { action: 'setPartnerOrdersConfig', patch: { creationOpen: true }, expectedVersion: 2, reason: 'Réouverture de test' }));
  assert.equal(reopen.success, true, JSON.stringify(reopen));
  const base = () => ({ lotId: lot.LOT_ID, completed: ['S0'], baselineOrderIds: manifest.baseline.orderIds });

  const store = memoryStore();
  await assert.rejects(runner.executeStep({ stepId: 'S5', state: base(), io, store, nowMs: NOW }), (e) => e.code === 'OUT_OF_ORDER');
  await assert.rejects(runner.executeStep({ stepId: 'S0', state: base(), io, store, nowMs: NOW }), (e) => e.code === 'ALREADY_DONE');
  await assert.rejects(runner.executeStep({ stepId: 'S99', state: base(), io, store, nowMs: NOW }), (e) => e.code === 'UNKNOWN_STEP');
  assert.equal(store.saved(), null, 'un refus d’ordre n’écrit rien');

  // Heure de nuit : le total retourné par le serveur (jour) ne correspond pas au barème → arrêt, jamais d'hypothèse « jour ».
  const nightState = { ...base(), startWallets: await wallets() };
  await assert.rejects(runner.executeStep({ stepId: 'S1', state: nightState, io, store, nowMs: NIGHT }), (e) => e.code === 'AMOUNT_MISMATCH');
  assert.equal(nightState.failed.step, 'S1');
  await assert.rejects(runner.executeStep({ stepId: 'S2', state: nightState, io, store, nowMs: NOW }), (e) => e.code === 'PREVIOUS_FAILURE', 'jamais de poursuite après erreur');
  assert.equal(JSON.parse(store.saved()).failed.code, 'AMOUNT_MISMATCH');
  assert.deepEqual(lot.expectedAmounts({ nowMs: NIGHT }).totalAmount, 7500);

  // Une erreur du serveur contenant un secret est masquée dans l'état enregistré.
  const leaky = { ...io, call: async () => { throw new Error('refus pour le PIN 123456 eyJabc.def.ghi'); } };
  const st = { ...base(), secrets: { pickup: { pin: '123456', token: 'tk-secret' } } };
  await assert.rejects(runner.executeStep({ stepId: 'S1', state: st, io: leaky, store: memoryStore(), nowMs: NOW }));
  assert.ok(!/123456|eyJ/.test(JSON.stringify(st.failed)), JSON.stringify(st.failed));

  // Mauvaise identité : l'exécuteur refuse un uid hors lot avant tout appel.
  const wrongId = { ...io, identity: async () => ({ uid: 'real-client' }), call: async () => { throw new Error('ne doit pas être appelé'); } };
  const st2 = { ...base() };
  await assert.rejects(runner.executeStep({ stepId: 'S1', state: st2, io: wrongId, store: memoryStore(), nowMs: NOW }), (e) => e.code === 'WRONG_IDENTITY');
});

test('4. GPS : fraîcheur 180 s, GPS périmé, aucun livreur éligible, rafraîchissement juste avant le dispatch', options, async () => {
  const amounts = lot.expectedAmounts({ nowMs: NOW });
  const startClient = (await wallets()).client;
  const place = async () => {
    const quote = await run.quote(asUser(CLIENT, choices()));
    assert.equal(quote.success, true, JSON.stringify(quote));
    const o = await run.create(asUser(CLIENT, { ...choices(), quoteId: quote.data.quoteId, paymentMethod: 'wallet', confirmedAmount: quote.data.total, deliveryAddress: 'Adresse fictive' }));
    assert.equal(o.success, true, JSON.stringify(o));
    return o.data.orderId;
  };
  const dispatchOutcome = async (orderId) => (await run.action(asUser(RESTO, { orderId, action: 'acceptPartnerOrder' }))).data.dispatch;
  const refuse = async (orderId) => run.action(asUser(RESTO, { orderId, action: 'refusePartnerOrder' }));

  // GPS périmé (5 min) : le runner refuse S3 ; le serveur ne propose la course à personne.
  await db.doc(`livreurs/${DRIVER}`).update({ isOnline: true });
  await setGpsAge(5 * MIN);
  const a = await place();
  const stale = { lotId: lot.LOT_ID, completed: runner.ORDER_OF_STEPS.slice(0, 4), baselineOrderIds: manifest.baseline.orderIds, orderId: a, quoteId: 'x', amounts, startWallets: lot.WALLETS, ledgerKey: 'afterCreate' };
  await assert.rejects(runner.executeStep({ stepId: 'S3', state: stale, io, store: memoryStore(), nowMs: NOW }), (e) => e.code === 'GPS_STALE');
  const d1 = await dispatchOutcome(a);
  assert.equal(d1.dispatched, false, `GPS périmé : ${JSON.stringify(d1)}`);
  assert.equal((await order(a)).status, 'pending');
  await refuse(a);

  // Limite de 180 s : 150 s accepté, 240 s refusé.
  await setGpsAge(150 * 1000);
  const b = await place();
  assert.equal((await dispatchOutcome(b)).dispatched, true, '150 s : encore frais');
  assert.equal((await order(b)).status, 'assigned');
  await refuse(b);
  await setGpsAge(240 * 1000);
  const c = await place();
  assert.equal((await dispatchOutcome(c)).dispatched, false, '240 s : périmé');
  await refuse(c);

  // Aucun livreur éligible : hors ligne (GPS pourtant frais).
  await prepare.refreshDriverGps({ admin, db });
  await db.doc(`livreurs/${DRIVER}`).update({ isOnline: false });
  const d = await place();
  assert.equal((await dispatchOutcome(d)).dispatched, false, 'livreur hors ligne');
  await refuse(d);

  // Rafraîchissement (S2b) immédiatement avant S3 : le runner l'accepte et la course est assignée.
  await db.doc(`livreurs/${DRIVER}`).update({ isOnline: true });
  const walletsBeforeE = await wallets();
  const e = await place();
  const state = { ...stale, failed: undefined, orderId: e, startWallets: walletsBeforeE, completed: runner.ORDER_OF_STEPS.slice(0, 3) };
  await runner.executeStep({ stepId: 'S2b', state, io, store: memoryStore(), nowMs: NOW });
  const r = await runner.executeStep({ stepId: 'S3', state, io, store: memoryStore(), nowMs: NOW });
  assert.equal(r.step, 'S3');
  assert.equal((await order(e)).status, 'assigned');
  await refuse(e);

  // Les commandes refusées sont remboursées : le client retrouve son solde.
  assert.equal((await wallets()).client, startClient, 'remboursements intégraux');
  assert.equal(amounts.totalAmount, 7000);
});

test('5. sécurité : mauvais compte, mauvais rôle, restaurant hors pilote, preuves émises par un tiers', options, async () => {
  const quote = await run.quote(asUser(CLIENT, choices()));
  const created = await run.create(asUser(CLIENT, { ...choices(), quoteId: quote.data.quoteId, paymentMethod: 'wallet', confirmedAmount: quote.data.total, deliveryAddress: 'Adresse fictive' }));
  const orderId = created.data.orderId;
  const before = await wallets();

  // Mauvais UID : un inconnu et un compte historique n'obtiennent ni devis ni action.
  await refused(run.quote(asUser('t7e-intrus', choices())));
  await refused(run.action(asUser('real-client', { orderId, action: 'acceptPartnerOrder' })));
  // Mauvais rôle : le client ne gère pas la préparation, le livreur ni le restaurant ne pilotent pas le pilote.
  await refused(run.action(asUser(CLIENT, { orderId, action: 'markReady' })));
  await refused(run.action(asUser(DRIVER, { orderId, action: 'acceptPartnerOrder' })));
  await refused(run.action(asUser(RESTO, lot.pilotConfigPlan().request)));
  await refused(run.action(asUser(CLIENT, lot.pilotConfigPlan().request)));
  await refused(run.accept(asUser(CLIENT, { orderId, acceptanceSelfieUrl: 'https://x' })));
  // Restaurant non autorisé par le pilote.
  const other = await run.quote(asUser(CLIENT, { ...choices(), sellerId: 'real-resto', items: [{ itemId: 'real-plat', qty: 1 }] }));
  assert.equal(other.error, 'PARTNER_NOT_IN_PILOT');
  // L'administrateur fictif ne peut pas désigner un partenaire hors lot via le runner (assertDataInLot) ; côté serveur, la
  // configuration reste une action de super-administrateur et un autre compte est refusé.
  assert.throws(() => runner.assertDataInLot({ action: 'setPartnerOrdersConfig', patch: { pilotPartnerIds: ['real-resto'] } }, { baselineOrderIds: [] }), (e) => e.code === 'OUT_OF_LOT');

  // Preuves : seul le restaurant émet la récupération, seul le client la livraison, seul le livreur affecté confirme.
  await refused(run.prepareProof(asUser(CLIENT, { orderId, type: 'pickup' })));
  await refused(run.prepareProof(asUser(DRIVER, { orderId, type: 'pickup' })));
  await refused(run.prepareProof(asUser(DRIVER, { orderId, type: 'delivery' })));
  await refused(run.pickup(asUser('real-client', { orderId, pin: '123456' })));
  await refused(run.deliver(asUser(RESTO, { orderId, proofPin: '123456' })));

  assert.deepEqual(await wallets(), before, 'aucun mouvement d’argent');
  assert.equal((await order(orderId)).status, 'pending');
  await run.action(asUser(RESTO, { orderId, action: 'refusePartnerOrder' }));
  assert.equal((await wallets()).client, before.client + 7000, 'commande de test remboursée');

  // Pilote refermé : plus de devis.
  // Fermeture d'urgence : la version réelle (3) est lue ; une modification concurrente est signalée sans bloquer la fermeture ;
  // elle reste possible après une erreur de l'exécuteur ; hors identité administrateur, elle est refusée.
  const failedState = { completed: ['S0'], configVersion: 1, failed: { step: 'S3', code: 'X', message: 'm' }, baselineOrderIds: manifest.baseline.orderIds };
  const wrongAdmin = { ...io, identity: async () => ({ uid: CLIENT }) };
  await assert.rejects(runner.closePilot({ state: failedState, io: wrongAdmin, store: memoryStore() }), (e) => e.code === 'WRONG_IDENTITY');
  const closedAfterFailure = await runner.closePilot({ state: failedState, io, store: memoryStore() });
  assert.deepEqual([closedAfterFailure.closed, closedAfterFailure.version, closedAfterFailure.versionDivergedFromS0], [true, 4, true]);
  assert.equal((await run.quote(asUser(CLIENT, choices()))).error, 'CREATION_CLOSED');
});

test('6. historique intact : commandes, comptes et jeton FCM existants identiques', options, async () => {
  assert.equal((await db.doc('orders/hist-1').get()).data().status, 'delivered');
  assert.equal((await db.doc('clients/real-client').get()).data().wallet, 12345);
  assert.equal((await db.doc('clients/real-client').get()).data().fcmToken, 'PLACEHOLDER-NOT-A-REAL-TOKEN');
  assert.equal((await db.doc('restaurants/real-resto').get()).data().wallet, 5000);
});
