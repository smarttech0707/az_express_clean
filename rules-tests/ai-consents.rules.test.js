'use strict';

// ai_consents/{uid} : consentement au partage avec les fournisseurs d'IA
// (Anthropic, Google). Lecture par le propriétaire ou un super-admin ;
// aucune écriture cliente. Les écritures serveur (Admin SDK, azIaChat)
// contournent les règles : simulées par withSecurityRulesDisabled.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');

let env;
const password = { firebase: { sign_in_provider: 'password' } };

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT || 'az-express-rules-test',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8') },
  });
});
test.after(async () => env?.cleanup());
test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('ai_consents/u1').set({ granted: true, version: 1, providers: ['anthropic', 'google'] });
    await db.doc('ai_consents/u2').set({ granted: false, version: 1, providers: ['anthropic', 'google'] });
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: [] });
  });
});

const as = (uid) => env.authenticatedContext(uid, password).firestore();

test('le propriétaire lit son consentement', async () => {
  const snap = await assertSucceeds(as('u1').doc('ai_consents/u1').get());
  assert.equal(snap.data().granted, true);
});

test("un utilisateur ne lit pas le consentement d'un autre compte", async () => {
  await assertFails(as('u1').doc('ai_consents/u2').get());
  await assertFails(as('u2').doc('ai_consents/u1').get());
});

test('un compte non authentifié est refusé (lecture et écriture)', async () => {
  const anon = env.unauthenticatedContext().firestore();
  await assertFails(anon.doc('ai_consents/u1').get());
  await assertFails(anon.doc('ai_consents/u1').set({ granted: true, version: 1 }));
});

test('un compte anonyme Firebase ne lit pas le consentement d’un autre', async () => {
  const anon = env.authenticatedContext('x', { firebase: { sign_in_provider: 'anonymous' } }).firestore();
  await assertFails(anon.doc('ai_consents/u1').get());
});

test('aucune écriture cliente : ni accorder, ni retirer, ni créer, ni supprimer, même pour le propriétaire', async () => {
  const mine = as('u2').doc('ai_consents/u2');
  await assertFails(mine.set({ granted: true, version: 1 }));
  await assertFails(mine.update({ granted: true }));
  await assertFails(as('u1').doc('ai_consents/u1').update({ granted: false }));
  await assertFails(as('u1').doc('ai_consents/u1').delete());
  await assertFails(as('u3').doc('ai_consents/u3').set({ granted: true, version: 1 }));
  await assertFails(as('u1').doc('ai_consents/u2').update({ granted: true }));
});

test('aucune lecture de liste (pas d’énumération des consentements)', async () => {
  await assertFails(as('u1').collection('ai_consents').get());
});

test('un super-admin actif lit ; un sous-admin et un non-admin non', async () => {
  await assertSucceeds(as('root').doc('ai_consents/u1').get());
  await assertFails(as('sub').doc('ai_consents/u1').get());
  await assertFails(as('stranger').doc('ai_consents/u1').get());
  await assertFails(as('root').doc('ai_consents/u1').update({ granted: false })); // même un admin n'écrit pas
});

test("les écritures serveur (Admin SDK) fonctionnent et le propriétaire voit l'effet", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc('ai_consents/u2').set({ granted: true, version: 1, providers: ['anthropic', 'google'] }, { merge: true });
    await ctx.firestore().doc('ai_consents/u1').set({ granted: false, version: 1 }, { merge: true });
  });
  assert.equal((await assertSucceeds(as('u2').doc('ai_consents/u2').get())).data().granted, true);
  assert.equal((await assertSucceeds(as('u1').doc('ai_consents/u1').get())).data().granted, false);
});
