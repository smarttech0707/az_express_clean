// Confidentialité de `config/*` : LISTE D'AUTORISATION. Seuls commission, app_versions et app_version sont lisibles sans
// connexion (l'app les lit avant l'authentification : version minimale, barème de commission). Tout autre document —
// az_wallet, billing, driver_recharge, ou un document inconnu — est réservé au super-admin.
// Les Cloud Functions passent par l'Admin SDK (règles ignorées) : non concernées.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const FINANCIAL = ['az_wallet', 'billing', 'driver_recharge'];
const PUBLIC = ['commission', 'app_versions', 'app_version'];
const PRIVATE = [...FINANCIAL, 'app', 'theme', 'inconnu'];

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('config/az_wallet').set({ totalCommissions: 700, totalDeliveries: 7 });
    await db.doc('config/billing').set({ mode: 'separate' });
    await db.doc('config/driver_recharge').set({ minAmount: 500 });
    await db.doc('config/commission').set({ commissionBasic: 100 });
    await db.doc('config/app_versions').set({ livreur: { minBuild: 1 } });
    await db.doc('config/app_version').set({ minWalletPaymentBuild: 1 });
    await db.doc('config/app').set({ name: 'AZ' });
    await db.doc('config/theme').set({ color: 'orange' });
    await db.doc('config/inconnu').set({ x: 1 });
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] });
    await db.doc('clients/c1').set({ wallet: 100 });
  });
  return e;
}

test('config non publique (financière, inconnue) : refusée sans connexion', async () => {
  const e = await env('az-config-unauth');
  try {
    const db = e.unauthenticatedContext().firestore();
    for (const id of PRIVATE) await assertFails(db.doc(`config/${id}`).get());
  } finally { await e.cleanup(); }
});

test('config non publique : refusée à un client, un livreur, un sous-admin et un anonyme', async () => {
  const e = await env('az-config-roles');
  try {
    for (const uid of ['c1', 'driver1', 'sub']) {
      const db = e.authenticatedContext(uid, password).firestore();
      for (const id of PRIVATE) await assertFails(db.doc(`config/${id}`).get());
    }
    // Un utilisateur anonyme non plus.
    const anon = e.authenticatedContext('anon1', { firebase: { sign_in_provider: 'anonymous' } }).firestore();
    for (const id of PRIVATE) await assertFails(anon.doc(`config/${id}`).get());
  } finally { await e.cleanup(); }
});

test('config non publique : lisible par le super-admin', async () => {
  const e = await env('az-config-super');
  try {
    const db = e.authenticatedContext('root', password).firestore();
    for (const id of PRIVATE) await assertSucceeds(db.doc(`config/${id}`).get());
  } finally { await e.cleanup(); }
});

test('config publique : reste lisible sans connexion et connecté (l\'app en dépend)', async () => {
  const e = await env('az-config-public');
  try {
    const unauth = e.unauthenticatedContext().firestore();
    const client = e.authenticatedContext('c1', password).firestore();
    for (const id of PUBLIC) {
      await assertSucceeds(unauth.doc(`config/${id}`).get());
      await assertSucceeds(client.doc(`config/${id}`).get());
    }
    // Liste d'autorisation : un document de config absent de la liste (même vide ou inexistant) n'est pas public.
    await assertFails(unauth.doc('config/nouveau_document').get());
  } finally { await e.cleanup(); }
});

test('config : l\'écriture reste réservée au super-admin (financière ou non)', async () => {
  const e = await env('az-config-write');
  try {
    for (const uid of ['c1', 'sub']) {
      const db = e.authenticatedContext(uid, password).firestore();
      await assertFails(db.doc('config/az_wallet').set({ totalCommissions: 99999 }));
      await assertFails(db.doc('config/commission').set({ commissionBasic: 0 }));
    }
    await assertFails(e.unauthenticatedContext().firestore().doc('config/az_wallet').set({ totalCommissions: 1 }));
    await assertSucceeds(e.authenticatedContext('root', password).firestore().doc('config/commission').set({ commissionBasic: 100 }));
  } finally { await e.cleanup(); }
});

test('config : requête de liste de la collection interdite aux non-admins (documents financiers inclus)', async () => {
  const e = await env('az-config-list');
  try {
    const db = e.authenticatedContext('c1', password).firestore();
    await assertFails(db.collection('config').get());
    await assertSucceeds(e.authenticatedContext('root', password).firestore().collection('config').get());
  } finally { await e.cleanup(); }
});
