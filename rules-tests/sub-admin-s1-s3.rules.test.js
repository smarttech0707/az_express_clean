// Sous-administrateurs : S1 (règle `sellers`) et S3 (suppression `pharmacy_guards`).
// Contrat : un sous-admin « demandes_vendeurs » gère la FICHE d'un vendeur
// (6 champs) ; il ne touche jamais l'argent, l'abonnement, le VIP, la
// suspension, le statut ; il ne crée ni ne supprime de compte. Le super-admin
// conserve tous ses droits.
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };
const anonymous = { firebase: { sign_in_provider: 'anonymous' } };

const seller = {
  name: 'Boutique', phone: '0700000000', type: 'boutique', isActive: true,
  lat: 6.7, lng: -3.4, wallet: 5000, subscriptionStatus: 'active',
  subscriptionExpiresAt: 1, vipStatus: 'none', plan: 'standard',
  priorityLevel: 0, paymentStatus: 'paid', isSuspended: false, status: 'approved',
};

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/super1').set({ role: 'super', isActive: true });
    await db.doc('admins/subVend').set({ role: 'sub', isActive: true, permissions: ['demandes_vendeurs'] });
    await db.doc('admins/subOther').set({ role: 'sub', isActive: true, permissions: ['recharges'] });
    await db.doc('admins/subOff').set({ role: 'sub', isActive: false, permissions: ['demandes_vendeurs'] });
    await db.doc('sellers/s1').set(seller);
    await db.doc('pharmacy_guards/g1').set({ name: 'Garde', city: 'Abengourou' });
  });
  return e;
}
const as = (e, uid, token = password) => e.authenticatedContext(uid, token).firestore();

test('S1 : le sous-admin « demandes_vendeurs » modifie la fiche (6 champs autorisés)', async () => {
  const e = await env('az-s1-fiche');
  try {
    const db = as(e, 'subVend');
    await assertSucceeds(db.doc('sellers/s1').update({ name: 'Nouveau nom' }));
    await assertSucceeds(db.doc('sellers/s1').update({
      phone: '0711111111', type: 'boutique', isActive: false, lat: 6.8, lng: -3.5,
    }));
  } finally { await e.cleanup(); }
});

test('S1 : le sous-admin ne peut écrire AUCUN champ sensible du vendeur', async () => {
  const e = await env('az-s1-sensible');
  try {
    const db = as(e, 'subVend');
    const forbidden = {
      wallet: 999999, subscriptionStatus: 'expired', subscriptionExpiresAt: 99,
      vipStatus: 'vip', vipExpiresAt: 99, vipStartedAt: 1, plan: 'premium',
      priorityLevel: 9, paymentStatus: 'free', isSuspended: true, isDeleted: true,
      status: 'rejected', deletionRequested: true, uid: 'x',
    };
    for (const [k, v] of Object.entries(forbidden)) {
      await assertFails(db.doc('sellers/s1').update({ [k]: v })).catch((err) => { throw new Error('champ accepté : ' + k + ' — ' + err.message); });
    }
    // Mélange fiche + champ sensible : refusé en bloc.
    await assertFails(db.doc('sellers/s1').update({ name: 'X', wallet: 1 }));
    // Aucun effet des écritures refusées.
    let walletNow;
    await e.withSecurityRulesDisabled(async (c) => {
      walletNow = (await c.firestore().doc('sellers/s1').get()).data().wallet;
    });
    if (walletNow !== 5000) throw new Error('wallet modifié');
  } finally { await e.cleanup(); }
});

test('S1 : le sous-admin ne crée pas de vendeur ni ne supprime de document', async () => {
  const e = await env('az-s1-create-delete');
  try {
    const db = as(e, 'subVend');
    await assertFails(db.doc('sellers/new').set({ ...seller, wallet: 0 }));
    await assertFails(db.doc('sellers/new').set({ name: 'x' }));
    await assertFails(db.doc('sellers/s1').delete());
  } finally { await e.cleanup(); }
});

test('S1 : sans la permission, désactivé ou anonyme : aucun accès au vendeur', async () => {
  const e = await env('az-s1-sans-permission');
  try {
    for (const db of [as(e, 'subOther'), as(e, 'subOff'), as(e, 'super1', anonymous)]) {
      await assertFails(db.doc('sellers/s1').get());
      await assertFails(db.doc('sellers/s1').update({ name: 'Intrus' }));
      await assertFails(db.doc('sellers/new').set({ name: 'Intrus' }));
    }
  } finally { await e.cleanup(); }
});

test('S1 : le super-admin garde ses droits légitimes', async () => {
  const e = await env('az-s1-super');
  try {
    const db = as(e, 'super1');
    await assertSucceeds(db.doc('sellers/s1').get());
    await assertSucceeds(db.doc('sellers/s1').update({ name: 'Super', isSuspended: true }));
    await assertSucceeds(db.doc('sellers/created').set({ ...seller, wallet: 0 }));
    await assertSucceeds(db.doc('sellers/created').delete());
  } finally { await e.cleanup(); }
});

test('S1 : le vendeur propriétaire garde son contrat (pas de wallet, pas de statut)', async () => {
  const e = await env('az-s1-owner');
  try {
    await e.withSecurityRulesDisabled((c) => c.firestore().doc('sellers/own').set({ ...seller }));
    const db = as(e, 'own');
    await assertFails(db.doc('sellers/own').update({ wallet: 9999999 }));
    await assertFails(db.doc('sellers/own').update({ isActive: false }));
    await assertFails(db.doc('sellers/own').update({ subscriptionStatus: 'active', plan: 'premium' }));
  } finally { await e.cleanup(); }
});

test('S3 : suppression d\'une garde de pharmacie réservée au super-admin', async () => {
  const e = await env('az-s3-guards');
  try {
    // Ancienne clé (demandes_vendeurs), clé légitime pharmacies, autre clé : refusés.
    await e.withSecurityRulesDisabled((c) => c.firestore().doc('admins/subPharma')
      .set({ role: 'sub', isActive: true, permissions: ['pharmacies'] }));
    for (const uid of ['subVend', 'subPharma', 'subOther', 'subOff']) {
      await assertFails(as(e, uid).doc('pharmacy_guards/g1').delete());
    }
    await assertSucceeds(as(e, 'super1').doc('pharmacy_guards/g1').delete());
  } finally { await e.cleanup(); }
});
