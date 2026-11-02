// Document `admins/{uid}` : S7 (plus d'écriture client des champs OTP) et S8
// (liste officielle de permissions, refus des clés inconnues).
//
// Exécution : npm run test:rules
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8');
const password = { firebase: { sign_in_provider: 'password' } };

async function env(projectId) {
  const e = await initializeTestEnvironment({ projectId, firestore: { rules: RULES } });
  await e.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/super1').set({ role: 'super', isActive: true });
    await db.doc('admins/sub1').set({ role: 'sub', isActive: true, permissions: ['support'] });
    // Compte historique portant une clé aujourd'hui obsolète.
    await db.doc('admins/legacy').set({ role: 'sub', isActive: true, permissions: ['support', 'ancienne_cle'] });
  });
  return e;
}
const as = (e, uid) => e.authenticatedContext(uid, password).firestore();

test('S8 : le super-admin crée un sous-admin avec des clés officielles', async () => {
  const e = await env('az-s8-create');
  try {
    const db = as(e, 'super1');
    await assertSucceeds(db.doc('admins/new1').set({ role: 'sub', isActive: true, permissions: ['livreurs', 'auto_moto'] }));
    await assertSucceeds(db.doc('admins/new2').set({ role: 'sub', isActive: true, permissions: [] }));
  } finally { await e.cleanup(); }
});

test('S8 : clés inconnues ou mal formées refusées (création et mise à jour)', async () => {
  const e = await env('az-s8-unknown');
  try {
    const db = as(e, 'super1');
    for (const bad of [['root'], ['livreurs', 'admin'], ['*'], 'livreurs', [1], ['LIVREURS']]) {
      await assertFails(db.doc('admins/bad').set({ role: 'sub', isActive: true, permissions: bad }));
      await assertFails(db.doc('admins/sub1').update({ permissions: bad }));
    }
    await assertSucceeds(db.doc('admins/sub1').update({ permissions: ['support', 'sos'] }));
  } finally { await e.cleanup(); }
});

test('S8 : un compte historique avec une clé obsolète peut toujours être désactivé', async () => {
  const e = await env('az-s8-legacy');
  try {
    const db = as(e, 'super1');
    await assertSucceeds(db.doc('admins/legacy').update({ isActive: false }));
    // …mais on ne peut pas modifier la liste en conservant une clé invalide.
    await assertFails(db.doc('admins/legacy').update({ permissions: ['support', 'ancienne_cle', 'sos'] }));
    await assertSucceeds(db.doc('admins/legacy').update({ permissions: ['support'] }));
  } finally { await e.cleanup(); }
});

test('S8 : le super-admin peut toujours supprimer un sous-admin ; un sous-admin non', async () => {
  const e = await env('az-s8-delete');
  try {
    await assertFails(as(e, 'sub1').doc('admins/legacy').delete());
    await assertSucceeds(as(e, 'super1').doc('admins/legacy').delete());
  } finally { await e.cleanup(); }
});

test('S7 : un admin n\'écrit plus les champs OTP de son document', async () => {
  const e = await env('az-s7-otp');
  try {
    for (const uid of ['sub1', 'super1']) {
      const db = as(e, uid);
      for (const field of ['otpHash', 'otpCode', 'otpExpiry', 'otpAttempts']) {
        if (uid === 'super1') continue; // le super-admin garde l'écriture complète sur les autres comptes
        await assertFails(db.doc(`admins/${uid}`).update({ [field]: 'x' }));
      }
    }
  } finally { await e.cleanup(); }
});

test('un admin met à jour son jeton de notification et sa photo, rien d\'autre', async () => {
  const e = await env('az-s7-owner');
  try {
    const db = as(e, 'sub1');
    await assertSucceeds(db.doc('admins/sub1').update({ fcmToken: 'jeton-notification-1' }));
    await assertSucceeds(db.doc('admins/sub1').update({ photoUrl: 'https://exemple/p.png' }));
    await assertFails(db.doc('admins/sub1').update({ permissions: ['support', 'recharges'] }));
    await assertFails(db.doc('admins/sub1').update({ role: 'super' }));
    await assertFails(db.doc('admins/sub1').update({ isActive: false }));
    await assertFails(db.doc('admins/sub1').update({ fcmToken: 'x', role: 'super' }));
  } finally { await e.cleanup(); }
});
