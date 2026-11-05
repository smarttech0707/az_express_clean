// Mission 7E-11-S — confidentialité des selfies d'acceptation (acceptance_selfies/{commande}/{fichier}) et des photos de preuve de
// livraison (delivery_photos/{livreur}/{fichier}). Lecture et liste réservées au livreur propriétaire et au super-administrateur ;
// écriture réservée au livreur dans son propre espace (nom de fichier imposé) ; aucune lecture Firestore sur le chemin critique
// d'acceptation (limite de production : 2 documents par évaluation, que l'émulateur n'applique pas : section statique en fin de fichier).
//
// Les clients, restaurateurs et administrateurs affichent ces images par l'URL de téléchargement stockée dans la commande
// (jeton intégré, sans règle) : aucune lecture SDK d'un tiers n'est nécessaire (audit des usages Flutter et Cloud Functions).
//
// Exécution : npm run test:storage
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { ref, uploadBytes, deleteObject, getBytes, getDownloadURL, listAll } = require('firebase/storage');

const RULES_PATH = process.env.STORAGE_RULES_PATH || path.join(__dirname, '..', 'storage.rules');
let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT || 'demo-az-selfie-photos',
    storage: { rules: fs.readFileSync(RULES_PATH, 'utf8') },
    firestore: {},
  });
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc('admins/root').set({ role: 'super', isActive: true });
    await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] });
    await db.doc('orders/O1').set({ clientId: 'c1', driverId: 'd1', sellerId: 'r1', status: 'accepted' });
    const st = ctx.storage();
    const img = { contentType: 'image/jpeg' };
    await uploadBytes(ref(st, 'acceptance_selfies/O1/d1.jpg'), jpeg, img);
    await uploadBytes(ref(st, 'delivery_photos/d1/O1.jpg'), jpeg, img);
  });
});
test.after(async () => env?.cleanup());

const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const img = { contentType: 'image/jpeg' };
const password = { firebase: { sign_in_provider: 'password' } };
const anonymous = { firebase: { sign_in_provider: 'anonymous' } };
const st = (uid, token = password) => env.authenticatedContext(uid, token).storage();
const selfie = (s, file = 'd1.jpg', order = 'O1') => ref(s, `acceptance_selfies/${order}/${file}`);
const photo = (s, driver = 'd1', file = 'O1.jpg') => ref(s, `delivery_photos/${driver}/${file}`);
const OUTSIDERS = [['livreur d2', 'd2'], ['client c1', 'c1'], ['restaurateur r1', 'r1'], ['sous-admin', 'sub'], ['inconnu', 'x']];

test('lecture d\'un selfie d\'acceptation : propriétaire et super-administrateur seulement', async () => {
  await assertSucceeds(getBytes(selfie(st('d1'))));
  await assertSucceeds(getBytes(selfie(st('root'))));
  for (const [label, uid] of OUTSIDERS) await assertFails(getBytes(selfie(st(uid))), label);
  await assertFails(getBytes(selfie(st('anon', anonymous))), 'anonyme');
  await assertFails(getBytes(selfie(env.unauthenticatedContext().storage())), 'non connecté');
});

test('lecture d\'une photo de livraison : propriétaire et super-administrateur seulement', async () => {
  await assertSucceeds(getBytes(photo(st('d1'))));
  await assertSucceeds(getBytes(photo(st('root'))));
  for (const [label, uid] of OUTSIDERS) await assertFails(getBytes(photo(st(uid))), label);
  await assertFails(getBytes(photo(st('anon', anonymous))), 'anonyme');
  await assertFails(getBytes(photo(env.unauthenticatedContext().storage())), 'non connecté');
});

test('liste des dossiers : un tiers ne peut énumérer ni les commandes ni les photos d\'un livreur', async () => {
  for (const [label, uid] of OUTSIDERS) {
    await assertFails(listAll(ref(st(uid), 'delivery_photos/d1')), `photos ${label}`);
    await assertFails(listAll(ref(st(uid), 'acceptance_selfies/O1')), `selfies ${label}`);
  }
  await assertFails(listAll(ref(st('anon', anonymous), 'delivery_photos/d1')), 'anonyme');
  await assertFails(listAll(ref(st('x'), 'acceptance_selfies')), 'racine des selfies');
  await assertFails(listAll(ref(st('x'), 'delivery_photos')), 'racine des photos');
});

test('parcours de livraison inchangé : le livreur envoie son selfie puis obtient son URL, remplace et supprime son fichier', async () => {
  const s = st('d1');
  await assertSucceeds(uploadBytes(selfie(s, 'd1.jpg', 'O2'), jpeg, img));
  await assertSucceeds(getDownloadURL(selfie(s, 'd1.jpg', 'O2'))); // l'application lit l'URL juste après l'envoi
  await assertSucceeds(uploadBytes(selfie(s, 'd1.jpg', 'O2'), jpeg, img)); // rejeu après coupure réseau
  await assertSucceeds(deleteObject(selfie(s, 'd1.jpg', 'O2')));
  await assertSucceeds(uploadBytes(photo(s, 'd1', 'O2.jpg'), jpeg, img));
  await assertSucceeds(getDownloadURL(photo(s, 'd1', 'O2.jpg')));
  await assertSucceeds(deleteObject(photo(s, 'd1', 'O2.jpg')));
});

test('selfie d\'acceptation : seul le fichier portant l\'identifiant de l\'appelant, image ≤ 5 Mo, compte non anonyme', async () => {
  await assertFails(uploadBytes(selfie(st('d1'), 'd2.jpg'), jpeg, img), 'au nom d\'un autre');
  await assertFails(uploadBytes(selfie(st('d1'), 'd1.png'), jpeg, img), 'autre nom');
  await assertFails(uploadBytes(selfie(st('d1'), 'd1.jpg'), jpeg, { contentType: 'application/pdf' }), 'pas une image');
  await assertFails(uploadBytes(selfie(st('d1'), 'd1.jpg'), new Uint8Array(6 * 1024 * 1024), img), 'trop gros');
  await assertFails(uploadBytes(selfie(st('anon', anonymous), 'anon.jpg'), jpeg, img), 'anonyme');
  await assertFails(uploadBytes(selfie(env.unauthenticatedContext().storage(), 'x.jpg'), jpeg, img), 'non connecté');
  await assertFails(deleteObject(selfie(st('d2'), 'd1.jpg')), 'suppression par un tiers');
  await assertFails(deleteObject(selfie(st('root'), 'd1.jpg')), 'suppression par un administrateur');
});

test('photo de livraison : espace du livreur seulement, nom de fichier sûr, image ≤ 10 Mo', async () => {
  await assertFails(uploadBytes(photo(st('d2'), 'd1', 'O9.jpg'), jpeg, img), 'dans l\'espace d\'un autre');
  await assertFails(uploadBytes(photo(st('anon', anonymous), 'anon', 'O9.jpg'), jpeg, img), 'anonyme');
  await assertFails(uploadBytes(photo(st('d1'), 'd1', 'O9.jpg'), jpeg, { contentType: 'video/mp4' }), 'pas une image');
  await assertFails(uploadBytes(photo(st('d1'), 'd1', 'O9.jpg'), new Uint8Array(11 * 1024 * 1024), img), 'trop gros');
  for (const bad of ['script.php', 'O9.png', '.jpg', `${'a'.repeat(129)}.jpg`, 'a b.jpg', 'O9.jpg.exe']) {
    await assertFails(uploadBytes(photo(st('d1'), 'd1', bad), jpeg, img), `nom refusé : ${bad}`);
  }
  for (const good of ['O9.jpg', 'order-123_A.jpg']) await assertSucceeds(uploadBytes(photo(st('d1'), 'd1', good), jpeg, img));
  await assertFails(deleteObject(photo(st('d2'), 'd1', 'O9.jpg')), 'suppression par un tiers');
  await assertFails(deleteObject(photo(st('root'), 'd1', 'O9.jpg')), 'suppression par un administrateur');
  await assertSucceeds(deleteObject(photo(st('d1'), 'd1', 'O9.jpg')));
});

// ── Budget de documents Firestore (limite de production : 2 par évaluation ; non appliquée par l'émulateur) ──────────────
function matchBlock(rules, pathPattern) {
  const start = rules.indexOf(`match ${pathPattern} {`);
  assert.ok(start >= 0, pathPattern);
  let depth = 0; let i = start + `match ${pathPattern} `.length; // l'accolade du bloc, pas celles des jokers {orderId}
  for (; i < rules.length; i++) { if (rules[i] === '{') depth++; if (rules[i] === '}' && --depth === 0) break; }
  return rules.slice(start, i + 1);
}
const stripComments = (t) => t.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

test('budget statique : aucune lecture Firestore propre au chemin ; le chemin du propriétaire ne dépasse jamais le tombstone de isAuth()', () => {
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  for (const p of ['/acceptance_selfies/{orderId}/{file}', '/delivery_photos/{driverId}/{file}']) {
    const block = stripComments(matchBlock(rules, p));
    assert.ok(!/firestore\.(get|exists)\(/.test(block), `${p} : aucune lecture directe`);
    const clauses = [...block.matchAll(/allow ([a-z, ]+):\s*if ([^;]+);/g)].map((m) => ({ ops: m[1], expr: m[2] }));
    assert.ok(clauses.length >= 3, p);
    for (const c of clauses) {
      const usesAdmin = /isSuperAdminReader\(\)/.test(c.expr);
      const usesAuth = /isAuth\(\)|isRealUser\(\)|isOwnerPath\(/.test(c.expr);
      // Le tombstone (isAuth/isRealUser/isOwnerPath) = 1 document ; le lecteur administrateur = admins/{uid} = 1 document.
      // Jamais les deux dans la même expression : sinon 2 documents + éventuels autres → au bord de la limite.
      assert.ok(!(usesAdmin && usesAuth), `${p} : ${c.ops} combine administrateur et tombstone`);
    }
    const admin = clauses.filter((c) => /isSuperAdminReader\(\)/.test(c.expr));
    assert.equal(admin.length, 1, `${p} : une clause administrateur distincte`);
    assert.match(admin[0].ops, /read/);
  }
});

test('le déploiement de la préproduction ne comporte aucune étape Storage (aucune règle déployée par ce lot)', () => {
  const script = fs.readFileSync(path.join(__dirname, '..', 'test-env', 'deploy-restaurant-v2-preprod.ps1'), 'utf8');
  assert.ok(!/firebase deploy[^\n]*storage/i.test(script) && !/'storage'/.test(script));
});
