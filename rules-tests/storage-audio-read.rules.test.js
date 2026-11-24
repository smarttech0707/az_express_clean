// Lectures audio Storage (voice_messages, chat_audio, mp_chat_audio) : vérifie
// les autorisations après la refonte à 2 documents Firestore au pire par
// requête. L'émulateur N'APPLIQUE PAS cette limite de production : le budget
// est établi par lecture des règles (voir commentaires de storage.rules), pas
// par ces tests.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { ref, uploadBytes, getBytes } = require('firebase/storage');

const RULES_PATH = path.join(__dirname, '..', 'storage.rules');
const rules = fs.readFileSync(RULES_PATH, 'utf8');
let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT || 'az-express-b0469',
    storage: { rules },
    firestore: {},
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: [] });
    await db.doc('admins/off').set({ role: 'super', isActive: false });
    await db.doc('orders/o1').set({ clientId: 'client1', driverId: 'driver1' });
    await db.doc('marketplace_chats/mp_p1_buyer1').set({ sellerId: 's1', buyerId: 'buyer1' });
    await db.doc('account_tombstones/gone').set({ deletedAt: 1 });
    await db.doc('orders/o2').set({ clientId: 'gone', driverId: 'driver1' });
    for (const p of ['voice_messages/o1/a.mp3', 'chat_audio/o1/a.mp3', 'mp_chat_audio/mp_p1_buyer1/a.mp3',
      'voice_messages/o2/a.mp3']) {
      await ctx.storage().ref(p).put(new Uint8Array([1, 2, 3]), { contentType: 'audio/mpeg' });
    }
  });
});
test.after(async () => env?.cleanup());

const password = { firebase: { sign_in_provider: 'password' } };
const anon = { firebase: { sign_in_provider: 'anonymous' } };
const st = (uid, token = password) => env.authenticatedContext(uid, token).storage();
const read = (storage, p) => getBytes(ref(storage, p));

for (const folder of ['voice_messages', 'chat_audio']) {
  test(`${folder} : client et livreur de la commande lisent`, async () => {
    await assertSucceeds(read(st('client1'), `${folder}/o1/a.mp3`));
    await assertSucceeds(read(st('driver1'), `${folder}/o1/a.mp3`));
  });
  test(`${folder} : super-admin lit, sous-admin et inactif non`, async () => {
    await assertSucceeds(read(st('root'), `${folder}/o1/a.mp3`));
    await assertFails(read(st('sub'), `${folder}/o1/a.mp3`));
    await assertFails(read(st('off'), `${folder}/o1/a.mp3`));
  });
  test(`${folder} : tiers, anonyme et non connecté refusés`, async () => {
    await assertFails(read(st('stranger'), `${folder}/o1/a.mp3`));
    await assertFails(read(st('stranger', anon), `${folder}/o1/a.mp3`));
    await assertFails(read(env.unauthenticatedContext().storage(), `${folder}/o1/a.mp3`));
  });
}

test('voice_messages : un participant tombstoné est refusé', async () => {
  await assertFails(read(st('gone'), 'voice_messages/o2/a.mp3'));
  await assertSucceeds(read(st('driver1'), 'voice_messages/o2/a.mp3'));
});

test('mp_chat_audio : acheteur, vendeur et super-admin lisent ; tiers refusé', async () => {
  const p = 'mp_chat_audio/mp_p1_buyer1/a.mp3';
  await assertSucceeds(read(st('buyer1'), p));
  await assertSucceeds(read(st('s1'), p));
  await assertSucceeds(read(st('root'), p));
  await assertFails(read(st('buyer2'), p));
  await assertFails(read(st('sub'), p));
  await assertFails(read(st('stranger', anon), p));
});
