// Mission 7C-1-S — création directe (historique) de commandes Restaurant/Boulangerie pour les partenaires pilotes.
// Un partenaire listé dans config/partnerOrdersV2.pilotPartnerIds ne reçoit plus de commande créée par un client sans
// devis serveur. Document absent, liste absente/vide/invalide, autres partenaires et autres types : inchangés. Seule la
// CRÉATION est concernée : les commandes déjà créées restent lisibles.
//
// Exécution : npm run test:rules
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

async function env(projectId, config) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    for (const uid of ['c1', 'c2']) await db.doc(`clients/${uid}`).set({ wallet: 5000, fakeOrderCount: 0, cashOnDeliveryEnabled: true });
    await db.doc('restaurants/r1').set({ name: 'Pilote' });
    await db.doc('restaurants/r2').set({ name: 'Hors pilote' });
    await db.doc('boulangeries/b1').set({ name: 'Boulangerie pilote' });
    await db.doc('orders/existing').set({
      clientId: 'c1', sellerId: 'r1', sellerType: 'restaurant', status: 'pending', paymentMethod: 'cash', isPaid: false, budget: 1500,
    });
    if (config !== undefined) await db.doc('config/partnerOrdersV2').set(config);
  });
  return e;
}

const legacy = (clientId, sellerType, sellerId, extra = {}) => ({
  clientId, sellerType, sellerId, type: sellerType, budget: 1500, status: 'pending', paymentMethod: 'cash', isPaid: false, ...extra,
});
const cashCreate = (e, uid, id, sellerType, sellerId) => e.authenticatedContext(uid, password).firestore().doc(`orders/${id}`).set(legacy(uid, sellerType, sellerId));
async function walletCreate(e, uid, id, sellerType, sellerId, budget = 1500) {
  const db = e.authenticatedContext(uid, password).firestore();
  const batch = db.batch();
  batch.update(db.doc(`clients/${uid}`), { wallet: 5000 - budget, lastPaidOrderId: id });
  batch.set(db.doc(`orders/${id}`), legacy(uid, sellerType, sellerId, { budget, isPaid: true, paymentMethod: 'wallet' }));
  return batch.commit();
}
// withSecurityRulesDisabled ne renvoie pas la valeur du callback : on la capture.
async function readAdmin(e, fn) { let out; await e.withSecurityRulesDisabled(async (ctx) => { out = await fn(ctx.firestore()); }); return out; }
const walletOf = (e, uid) => readAdmin(e, async (db) => (await db.doc(`clients/${uid}`).get()).data().wallet);
const ordersOf = (e) => readAdmin(e, async (db) => (await db.collection('orders').get()).docs.map((d) => d.id).sort());

test('sans configuration pilote (document absent) : créations historiques inchangées, cash et wallet', async () => {
  const e = await env('az-legacy-none');
  try {
    await assertSucceeds(cashCreate(e, 'c1', 'a1', 'restaurant', 'r1'));
    await assertSucceeds(walletCreate(e, 'c1', 'a2', 'restaurant', 'r1'));
    await assertSucceeds(cashCreate(e, 'c2', 'a3', 'boulangerie', 'b1'));
  } finally { await e.cleanup(); }
});

test('liste absente, vide ou invalide : aucun pilote, aucun blocage (et aucune erreur d’évaluation)', async () => {
  for (const [i, config] of [{}, { pilotPartnerIds: [] }, { pilotPartnerIds: 'r1' }, { pilotPartnerIds: { r1: true } }, { pilotPartnerIds: null }].entries()) {
    const e = await env(`az-legacy-bad-${i}`, config);
    try {
      await assertSucceeds(cashCreate(e, 'c1', 'a1', 'restaurant', 'r1'));
      await assertSucceeds(cashCreate(e, 'c2', 'a2', 'boulangerie', 'b1'));
    } finally { await e.cleanup(); }
  }
});

test('partenaire pilote : création historique refusée pour tout client (cash et wallet, restaurant et boulangerie), soldes intacts', async () => {
  const e = await env('az-legacy-pilot', { pilotPartnerIds: ['r1', 'b1'] });
  try {
    for (const uid of ['c1', 'c2']) {
      await assertFails(cashCreate(e, uid, `x-${uid}-cash`, 'restaurant', 'r1'));
      await assertFails(walletCreate(e, uid, `x-${uid}-wallet`, 'restaurant', 'r1'));
      await assertFails(cashCreate(e, uid, `x-${uid}-bk`, 'boulangerie', 'b1'));
      await assertFails(walletCreate(e, uid, `x-${uid}-bkw`, 'boulangerie', 'b1', 1500));
    }
    assert.deepEqual(await ordersOf(e), ['existing']);
    assert.equal(await walletOf(e, 'c1'), 5000);
    assert.equal(await walletOf(e, 'c2'), 5000);
  } finally { await e.cleanup(); }
});

test('hors pilote et autres types : inchangés même quand la liste est renseignée (aucune fermeture globale)', async () => {
  const e = await env('az-legacy-others', { pilotPartnerIds: ['r1', 'b1'] });
  try {
    await assertSucceeds(cashCreate(e, 'c1', 'o1', 'restaurant', 'r2'));
    await assertSucceeds(walletCreate(e, 'c1', 'o2', 'restaurant', 'r2'));
    await assertSucceeds(cashCreate(e, 'c2', 'o3', 'pharmacie', 'r1'));      // même identifiant, autre type : non concerné
    await assertSucceeds(cashCreate(e, 'c2', 'o4', 'seller', 'r1'));         // marketplace
    await assertSucceeds(e.authenticatedContext('c2', password).firestore().doc('orders/o5').set({
      clientId: 'c2', budget: 1000, status: 'pending', paymentMethod: 'cash', isPaid: false, type: 'livraison',
    }));
  } finally { await e.cleanup(); }
});

test('retrait de la liste : le partenaire retrouve immédiatement l’ancien parcours', async () => {
  const e = await env('az-legacy-removed', { pilotPartnerIds: ['r1'] });
  try {
    await assertFails(cashCreate(e, 'c1', 'y1', 'restaurant', 'r1'));
    await e.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('config/partnerOrdersV2').set({ pilotPartnerIds: [] }));
    await assertSucceeds(cashCreate(e, 'c1', 'y2', 'restaurant', 'r1'));
  } finally { await e.cleanup(); }
});

test('commandes existantes d’un partenaire pilote : toujours lisibles ; la configuration n’est écrivable que par un administrateur', async () => {
  const e = await env('az-legacy-existing', { pilotPartnerIds: ['r1'] });
  try {
    await assertSucceeds(e.authenticatedContext('c1', password).firestore().doc('orders/existing').get());
    await assertSucceeds(e.authenticatedContext('r1', password).firestore().doc('orders/existing').get());
    await assertFails(e.authenticatedContext('c1', password).firestore().doc('config/partnerOrdersV2').set({ pilotPartnerIds: [] }));
    await assertFails(e.authenticatedContext('r1', password).firestore().doc('config/partnerOrdersV2').set({ pilotPartnerIds: ['r1', 'r2'] }));
    await assertFails(e.authenticatedContext('c1', password).firestore().doc('config/partnerOrdersV2').get());
    await assertFails(e.authenticatedContext('root', password).firestore().doc('config/partnerOrdersV2').set({ pilotPartnerIds: ['r1', 'r2'] }), 'même le super-administrateur : écriture réservée à setPartnerOrdersConfig');
  } finally { await e.cleanup(); }
});

test('les clients anonymes restent refusés et la création d’une commande v2 (champs serveur) reste interdite au client', async () => {
  const e = await env('az-legacy-anon', { pilotPartnerIds: [] });
  try {
    await assertFails(e.authenticatedContext('c1', { firebase: { sign_in_provider: 'anonymous' } }).firestore().doc('orders/z1').set(legacy('c1', 'restaurant', 'r2')));
    await assertFails(e.authenticatedContext('c1', password).firestore().doc('orders/z2').set(legacy('c1', 'restaurant', 'r2', { amountsVersion: 2 })));
  } finally { await e.cleanup(); }
});

// Mission 7C-2 : creationOpen / managementFrozen / version n'ont AUCUN effet sur les règles. L'arrêt des créations v2
// (creationOpen=false) ne doit jamais rouvrir l'ancien parcours d'un partenaire pilote ; la liste pilote seule décide.
test('creationOpen=false ne rouvre pas l’ancien parcours ; creationOpen=true sans liste ne bloque personne', async () => {
  const closed = await env('az-legacy-closed', { pilotPartnerIds: ['r1', 'b1'], creationOpen: false, managementFrozen: true, version: 7 });
  try {
    await assertFails(cashCreate(closed, 'c1', 'k1', 'restaurant', 'r1'));
    await assertFails(walletCreate(closed, 'c1', 'k2', 'restaurant', 'r1'));
    await assertFails(cashCreate(closed, 'c2', 'k3', 'boulangerie', 'b1'));
    await assertSucceeds(cashCreate(closed, 'c2', 'k4', 'restaurant', 'r2'));
    assert.equal(await walletOf(closed, 'c1'), 5000);
  } finally { await closed.cleanup(); }
  const open = await env('az-legacy-open', { pilotPartnerIds: [], creationOpen: true });
  try {
    await assertSucceeds(cashCreate(open, 'c1', 'k5', 'restaurant', 'r1'));
  } finally { await open.cleanup(); }
});

// Mission 7C-2 (correctif) : config/partnerOrdersV2 n'est modifiable QUE par setPartnerOrdersConfig (Admin SDK : validation,
// version, audit). Aucune écriture directe, quel que soit le rôle ; la lecture reste réservée aux administrateurs, et les
// règles/fonctions la lisent sans être soumises à ces règles.
test('config/partnerOrdersV2 : aucune écriture directe (client, partenaire, sous-admin, super-admin, anonyme) ; lecture super-admin conservée', async () => {
  const e = await env('az-legacy-config-lock', { pilotPartnerIds: ['r1'], creationOpen: true, managementFrozen: false, version: 3 });
  try {
    await e.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] }));
    const actors = {
      client: e.authenticatedContext('c1', password),
      partenaire: e.authenticatedContext('r1', password),
      'sous-admin': e.authenticatedContext('sub', password),
      'super-admin': e.authenticatedContext('root', password),
      anonyme: e.authenticatedContext('anon1', { firebase: { sign_in_provider: 'anonymous' } }),
      'non connecté': e.unauthenticatedContext(),
    };
    for (const [who, ctx] of Object.entries(actors)) {
      const ref = ctx.firestore().doc('config/partnerOrdersV2');
      await assertFails(ref.set({ pilotPartnerIds: ['r1', 'r2'], creationOpen: true }), 'set refusé : ' + who);
      await assertFails(ref.update({ managementFrozen: true }), 'update refusé : ' + who);
      await assertFails(ref.update({ creationOpen: false }), 'creationOpen refusé : ' + who);
      await assertFails(ref.delete(), 'delete refusé : ' + who);
    }
    const stored = await readAdmin(e, async (db) => (await db.doc('config/partnerOrdersV2').get()).data());
    assert.deepEqual([stored.pilotPartnerIds, stored.creationOpen, stored.managementFrozen, stored.version], [['r1'], true, false, 3], 'document inchangé');
    // Lecture : super-administrateur seulement (inchangé) ; l'évaluation des règles sur les commandes lit le document sans cette règle.
    await assertSucceeds(actors['super-admin'].firestore().doc('config/partnerOrdersV2').get());
    await assertFails(actors.client.firestore().doc('config/partnerOrdersV2').get());
    await assertFails(actors.partenaire.firestore().doc('config/partnerOrdersV2').get());
    await assertFails(cashCreate(e, 'c1', 'lock1', 'restaurant', 'r1'));
    await assertSucceeds(cashCreate(e, 'c2', 'lock2', 'restaurant', 'r2'));
    // Régression : les autres documents de config restent écrivables par le super-administrateur.
    await assertSucceeds(actors['super-admin'].firestore().doc('config/autre_reglage').set({ valeur: 1 }));
  } finally { await e.cleanup(); }
});
