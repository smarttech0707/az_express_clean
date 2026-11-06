'use strict';

// Mission 7E-41 — isolation des clients du pilote contre l'ÉMULATEUR Firestore (projet demo-az-t7e), avec les VRAIS modules
// (devis, création, action administrateur, garde super-administrateur). Aucun accès cloud.
//   firebase emulators:exec --config <config alternative> --only firestore --project demo-az-t7e \
//     "node --test functions/test/partnerOrderClientAllowlist.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST) && process.env.GCLOUD_PROJECT === 'demo-az-t7e';
const options = { skip: emulated ? false : 'émulateur Firestore requis (projet demo-az-t7e)' };
const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const prepare = require(path.join(dir, 'prepare'));

const NOW = Date.UTC(2026, 10, 6, 10, 0, 0);
const { client: CLIENT, restaurant: RESTO, admin: ADMIN } = Object.fromEntries(Object.entries(lot.IDENTITIES).map(([k, v]) => [k, v.uid]));
const EXISTING = 'existing-client'; // client réel hors lot, solde suffisant
const NEWCOMER = 'brand-new-client'; // inscription ouverte : compte Auth sans aucun document

let admin; let db; let run; let audits;
const user = (uid, data, provider = 'password') => ({ auth: { uid, token: { firebase: { sign_in_provider: provider } } }, data });
const noAuth = (data) => ({ data });
const choices = () => ({ sellerType: 'restaurant', sellerId: RESTO, items: lot.BASKET, destination: lot.DELIVERY_POINT });
const config = async () => (await db.doc('config/partnerOrdersV2').get()).data();
const setConfig = async (doc) => (doc === null ? db.doc('config/partnerOrdersV2').delete() : db.doc('config/partnerOrdersV2').set(doc));
const RESTRICTED = { pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], clientAccess: 'restricted', creationOpen: true, managementFrozen: false, version: 1 };
const wallet = async (p) => (await db.doc(p).get()).data().wallet;
const snapshotMoney = async () => ({
  lot: await wallet(`clients/${CLIENT}`), existing: await wallet(`clients/${EXISTING}`), resto: await wallet(`restaurants/${RESTO}`),
  orders: (await db.collection('orders').get()).size, quotes: (await db.collection('tariff_quotes').get()).size,
  txs: (await db.collection(`clients/${EXISTING}/wallet_transactions`).get()).size + (await db.collection(`clients/${CLIENT}/wallet_transactions`).get()).size,
});

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  db = admin.firestore();
  const { HttpsError } = require('firebase-functions/v2/https');
  const { calculateCommission } = require('../dispatch');
  const { requireSuperAdmin } = require('../adminGuards');
  const { buildQuotePartnerOrderCF, buildCreatePartnerOrderFromQuoteCF } = require('../partnerOrderQuote');
  const { buildPartnerOrderAction } = require('../partnerOrderActions');
  audits = [];
  const base = {
    db, admin, onCall: (...a) => ({ run: a[a.length - 1] }), HttpsError, checkRateLimit: async () => {},
    logAudit: async (entry) => { audits.push(entry); }, isEnabled: () => true,
  };
  run = {
    quote: buildQuotePartnerOrderCF({ ...base, now: () => NOW }).run,
    create: buildCreatePartnerOrderFromQuoteCF({ ...base, now: () => NOW }).run,
    action: buildPartnerOrderAction({ ...base, calculateCommission, requireSuperAdmin, dispatchAccepted: async () => ({ dispatched: false }) }).run,
  };
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${process.env.GCLOUD_PROJECT}/databases/(default)/documents`, { method: 'DELETE' });
  await db.doc('zones_livraison/abengourou-test').set({
    type: 'ville', name: 'Abengourou (test)', cityId: 'abengourou', isActive: true, isServiceable: true, coordinateSource: 'own', lat: 6.7273, lng: -3.4961, radiusKm: 8,
  });
  const users = new Map();
  const auth = {
    getUser: async (uid) => { if (!users.has(uid)) throw Object.assign(new Error('x'), { code: 'auth/user-not-found' }); return users.get(uid); },
    getUserByEmail: async (e) => { const u = [...users.values()].find((x) => x.email === e); if (!u) throw Object.assign(new Error('x'), { code: 'auth/user-not-found' }); return u; },
    createUser: async (p) => { users.set(p.uid, { uid: p.uid, email: p.email }); return users.get(p.uid); },
  };
  await prepare.executePrepare({ admin, db, auth, outDir: fs.mkdtempSync(path.join(os.tmpdir(), 't7e-allow-')) });
  await db.doc(`clients/${EXISTING}`).set({ name: 'Client existant', wallet: 50000 });
});

// Un refus peut être une erreur (HttpsError) ou une enveloppe {success:false}.
const refused = async (promise, label) => {
  let res;
  try { res = await promise; } catch (_) { return; }
  assert.equal(res && res.success, false, `refus attendu : ${label || ''} ${JSON.stringify(res)}`);
};
const refusedWith = (res, code) => { assert.equal(res.success, false, JSON.stringify(res)); assert.equal(res.error, code, JSON.stringify(res)); };
const quoteFor = async (uid, extra = {}) => run.quote(user(uid, { ...choices(), ...extra }));
const createFrom = (uid, q, extra = {}) => run.create(user(uid, { ...choices(), quoteId: q.data.quoteId, paymentMethod: 'wallet', confirmedAmount: q.data.total, deliveryAddress: 'Adresse fictive', ...extra }));

test('1. client du lot autorisé : devis, commande et rejeu idempotent', options, async () => {
  await setConfig(RESTRICTED);
  const q = await quoteFor(CLIENT);
  assert.equal(q.success, true, JSON.stringify(q));
  const o = await createFrom(CLIENT, q);
  assert.equal(o.success, true, JSON.stringify(o));
  assert.equal((await createFrom(CLIENT, q)).data.replayed, true);
  assert.equal(await wallet(`clients/${CLIENT}`), lot.WALLETS.client - q.data.total, 'un seul débit');
  // Remise à zéro de l'état pour la suite : commande annulée par le restaurant (remboursement), aucun effet de bord restant.
  const refused = await run.action(user(RESTO, { orderId: o.data.orderId, action: 'refusePartnerOrder' }));
  assert.equal(refused.success, true, JSON.stringify(refused));
  assert.equal(await wallet(`clients/${CLIENT}`), lot.WALLETS.client);
});

test('2-5, 11. refus sans aucune écriture : client existant hors lot, nouveau client, anonyme, non connecté, uid usurpé', options, async () => {
  await setConfig(RESTRICTED);
  const before = await snapshotMoney();

  refusedWith(await quoteFor(EXISTING), 'CLIENT_NOT_IN_PILOT');
  refusedWith(await quoteFor(NEWCOMER), 'CLIENT_NOT_IN_PILOT'); // refus avant toute lecture de compte : pas de CLIENT_NOT_FOUND
  await assert.rejects(run.quote(user('anon-1', choices(), 'anonymous')), (e) => e.code === 'unauthenticated');
  await assert.rejects(run.quote(noAuth(choices())), (e) => e.code === 'unauthenticated');
  await assert.rejects(run.create(noAuth({ ...choices(), quoteId: 'q', paymentMethod: 'wallet', deliveryAddress: 'a' })), (e) => e.code === 'unauthenticated');
  await assert.rejects(run.create(user('anon-1', { ...choices(), quoteId: 'q', paymentMethod: 'wallet', deliveryAddress: 'a' }, 'anonymous')), (e) => e.code === 'unauthenticated');

  // UID usurpé dans les paramètres : seul request.auth.uid compte.
  for (const spoof of [{ uid: CLIENT }, { clientId: CLIENT }, { userId: CLIENT }, { auth: { uid: CLIENT } }, { pilotClientIds: [EXISTING] }]) {
    refusedWith(await quoteFor(EXISTING, spoof), 'CLIENT_NOT_IN_PILOT');
  }

  // Création avec un devis forgé au nom d'un client hors lot (le devis n'est inscriptible que par le serveur : cas défensif).
  await db.doc('tariff_quotes/forged-1').set({
    kind: 'partner', uid: EXISTING, status: 'open', sellerType: 'restaurant', sellerId: RESTO, items: [], lines: [], fingerprint: 'x',
    productAmount: 6500, deliveryFee: 500, amount: 7000, expiresAtMs: NOW + 600000, pickup: lot.RESTAURANT_POINT, destination: lot.DELIVERY_POINT,
  });
  refusedWith(await run.create(user(EXISTING, { ...choices(), quoteId: 'forged-1', paymentMethod: 'wallet', confirmedAmount: 7000, deliveryAddress: 'a' })), 'CLIENT_NOT_IN_PILOT');
  // Devis d'un autre client : toujours introuvable (pas d'usurpation par quoteId).
  const q = await quoteFor(CLIENT);
  refusedWith(await createFrom(EXISTING, q), 'QUOTE_NOT_FOUND');
  await db.doc('tariff_quotes/forged-1').delete();
  await db.doc(`tariff_quotes/${q.data.quoteId}`).delete();

  // 16. Aucun mouvement financier, aucune commande, aucun devis supplémentaire.
  assert.deepEqual(await snapshotMoney(), before);
});

test('6-7. restaurant hors liste et pilote fermé refusés', options, async () => {
  await db.doc('restaurants/other-resto').set({ name: 'Autre', lat: 6.73, lng: -3.49, isOpen: true, isActive: true, wallet: 0 });
  await setConfig(RESTRICTED);
  refusedWith(await quoteFor(CLIENT, { sellerId: 'other-resto' }), 'PARTNER_NOT_IN_PILOT');
  await setConfig({ ...RESTRICTED, creationOpen: false });
  refusedWith(await quoteFor(CLIENT), 'CREATION_CLOSED');
  await setConfig(null);
  refusedWith(await quoteFor(CLIENT), 'PARTNER_NOT_IN_PILOT');
});

test('8-10, 15. liste absente, vide, malformée, ancienne configuration : tout est refusé (refus par défaut)', options, async () => {
  const { pilotClientIds, clientAccess, ...legacy } = RESTRICTED; // ancien document : aucun champ client
  const cases = {
    'ancienne configuration': legacy,
    'liste absente + mode restreint': { ...legacy, clientAccess: 'restricted' },
    'liste vide': { ...RESTRICTED, pilotClientIds: [] },
    'liste malformée (chaîne)': { ...RESTRICTED, pilotClientIds: CLIENT },
    'liste malformée (élément invalide)': { ...RESTRICTED, pilotClientIds: [CLIENT, 7] },
    'liste malformée (objet)': { ...RESTRICTED, pilotClientIds: { [CLIENT]: true } },
    'mode inconnu': { ...legacy, clientAccess: 'tous' },
  };
  const before = await snapshotMoney();
  for (const [label, doc] of Object.entries(cases)) {
    await setConfig(doc);
    const res = await quoteFor(CLIENT);
    assert.equal(res.success, false, label);
    assert.equal(res.error, 'CLIENT_NOT_IN_PILOT', label);
  }
  assert.deepEqual(await snapshotMoney(), before);
});

test('12. rejeu idempotent : refusé si le client n’est plus autorisé ; toléré seulement si la création est simplement fermée', options, async () => {
  await setConfig(RESTRICTED);
  const q = await quoteFor(CLIENT);
  const o = await createFrom(CLIENT, q);
  assert.equal(o.success, true, JSON.stringify(o));
  const debited = await wallet(`clients/${CLIENT}`);

  await setConfig({ ...RESTRICTED, pilotClientIds: [EXISTING] }); // client retiré de la liste
  refusedWith(await createFrom(CLIENT, q), 'CLIENT_NOT_IN_PILOT');
  await setConfig({ ...RESTRICTED, pilotPartnerIds: [] }); // partenaire retiré du pilote
  refusedWith(await createFrom(CLIENT, q), 'PARTNER_NOT_IN_PILOT');
  await setConfig(null); // configuration supprimée
  refusedWith(await createFrom(CLIENT, q), 'PARTNER_NOT_IN_PILOT');
  assert.equal(await wallet(`clients/${CLIENT}`), debited, 'aucun mouvement lors des rejeux refusés');

  // Arrêt d'urgence (creationOpen=false) : le client autorisé qui a perdu la réponse retrouve SA commande, sans second débit.
  await setConfig({ ...RESTRICTED, creationOpen: false });
  const replay = await createFrom(CLIENT, q);
  assert.equal(replay.success, true, JSON.stringify(replay));
  assert.equal(replay.data.replayed, true);
  assert.equal(replay.data.orderId, o.data.orderId);
  assert.equal(await wallet(`clients/${CLIENT}`), debited);
  // …mais aucune NOUVELLE commande n'est possible pendant l'arrêt.
  refusedWith(await quoteFor(CLIENT), 'CREATION_CLOSED');

  await setConfig(RESTRICTED);
  await run.action(user(RESTO, { orderId: o.data.orderId, action: 'refusePartnerOrder' }));
  assert.equal(await wallet(`clients/${CLIENT}`), lot.WALLETS.client);
});

test('13-14. liste modifiable par le seul super-administrateur ; modification versionnée et auditée ; ouverture générale explicite', options, async () => {
  await setConfig(null);
  audits.length = 0;
  const patch = { pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], clientAccess: 'restricted', creationOpen: true, managementFrozen: false };
  const request = { action: 'setPartnerOrdersConfig', patch, expectedVersion: 0, reason: 'Ouverture temporaire du pilote Restaurant v2 pour essai fictif T7E.' };

  // Non-administrateurs : le client autorisé, le client hors lot, le restaurant, un anonyme, personne.
  for (const uid of [CLIENT, EXISTING, RESTO]) await refused(run.action(user(uid, request)), uid);
  await assert.rejects(run.action(user('anon', request, 'anonymous')), (e) => e.code === 'unauthenticated');
  await assert.rejects(run.action(noAuth(request)), (e) => e.code === 'unauthenticated');
  assert.equal((await db.doc('config/partnerOrdersV2').get()).exists, false, 'aucune écriture par un non-administrateur');

  // Un client ne peut pas non plus s'ajouter lui-même via une action de gestion (pas de champ de ce type dans les autres actions).
  await refused(run.action(user(EXISTING, { orderId: 'x', action: 'acceptPartnerOrder', pilotClientIds: [EXISTING] })), 'action de gestion');

  // Administrateur : S0 exacte, auditée.
  const res = await run.action(user(ADMIN, request));
  assert.equal(res.success, true, JSON.stringify(res));
  assert.deepEqual(res.data.config, { pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], clientAccess: 'restricted', creationOpen: true, managementFrozen: false, version: 1 });
  const doc = await config();
  assert.deepEqual([doc.version, doc.updatedBy, doc.lastChange.by], [1, ADMIN, ADMIN]);
  const audit = audits.find((a) => a.action === 'partner_orders_config_update' && !a.status);
  assert.equal(audit.userId, ADMIN);
  assert.equal(audit.metadata.before.version, 0);
  assert.deepEqual(audit.metadata.after.pilotClientIds, [CLIENT]);
  assert.equal(audit.metadata.generalOpening, false);
  assert.match(audit.metadata.reason, /essai fictif T7E/);

  // Concurrence : mauvaise version refusée et auditée comme refus.
  refusedWith(await run.action(user(ADMIN, { ...request, expectedVersion: 0 })), 'CONFIG_CONFLICT');

  // Ouverture générale : jamais implicite.
  refusedWith(await run.action(user(ADMIN, { action: 'setPartnerOrdersConfig', patch: { clientAccess: 'open' }, expectedVersion: 1, reason: 'Ouverture à tous les clients' })), 'GENERAL_OPENING_NOT_CONFIRMED');
  assert.equal((await config()).clientAccess, 'restricted');
  refusedWith(await quoteFor(EXISTING), 'CLIENT_NOT_IN_PILOT');
  const opened = await run.action(user(ADMIN, { action: 'setPartnerOrdersConfig', patch: { clientAccess: 'open' }, expectedVersion: 1, reason: 'Ouverture à tous les clients', confirmGeneralOpening: true }));
  assert.equal(opened.success, true, JSON.stringify(opened));
  assert.equal(audits.filter((a) => a.action === 'partner_orders_config_update' && a.metadata && a.metadata.generalOpening === true).length, 1);
  const q = await quoteFor(EXISTING);
  assert.equal(q.success, true, 'ouverture générale : un client quelconque peut obtenir un devis');
  const back = await run.action(user(ADMIN, { action: 'setPartnerOrdersConfig', patch: { clientAccess: 'restricted' }, expectedVersion: 2, reason: 'Retour au mode restreint' }));
  assert.equal(back.success, true);
  refusedWith(await quoteFor(EXISTING), 'CLIENT_NOT_IN_PILOT');
  assert.deepEqual((await config()).pilotClientIds, [CLIENT], 'la liste est conservée');
  await db.doc(`tariff_quotes/${q.data.quoteId}`).delete();
});
