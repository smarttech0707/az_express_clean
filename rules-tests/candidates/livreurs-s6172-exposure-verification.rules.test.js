'use strict';

// SEC-01 / S6.17.2 — Fichier de test TEMPORAIRE et ISOLÉ, créé uniquement pour
// exécuter les 4 tests complémentaires demandés par cette phase, afin de ne
// modifier ni le fichier de test principal de S6.16/S6.17
// (`rules-tests/livreurs-read-tightening.rules.test.js`) ni aucun fichier de
// Rules (réel ou candidat). Charge le MÊME fichier candidat déjà validé et
// corrigé en S6.17 (`rules-tests/candidates/livreurs_tightened.rules`),
// sans le modifier. Données entièrement fictives.
//
// Exécution : firebase --config <config emulateur temporaire, port alternatif>
// emulators:exec --only firestore "node --test rules-tests/candidates/livreurs-s6172-exposure-verification.rules.test.js"

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'az-express-rules-test-s6172-exposure',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, 'livreurs_tightened.rules'), 'utf8'),
    },
  });
});

test.after(async () => {
  await testEnv.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

function asAdmin(uid) {
  return testEnv.authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore();
}
async function seed(fn) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => fn(ctx.firestore()));
}

// ═════════════════════════════════════════════════════════════════════════
// TEST 1 — Exposition des données privées à un sous-admin sans permission
// pertinente (preuve de contenu, pas seulement succès/échec)
// ═════════════════════════════════════════════════════════════════════════

test('TEST 1 : sous-admin sans permission pertinente — phone et wallet sont effectivement retournés', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/driver-fictif-1').set({
      phone: '+225 07 00 00 00 01',   // donnée fictive
      wallet: 12345,                   // donnée fictive
      lat: 6.7300,                     // donnée fictive
      lng: -3.4900,                    // donnée fictive
    });
    await db.doc('admins/sub-sans-permission').set({
      role: 'sub', isActive: true, permissions: ['tricycle'],
    });
  });

  const snap = await assertSucceeds(
    asAdmin('sub-sans-permission').doc('livreurs/driver-fictif-1').get(),
  );
  const data = snap.data();

  assert.equal(data.phone, '+225 07 00 00 00 01');
  assert.equal(data.wallet, 12345);
  assert.equal(data.lat, 6.7300);
  assert.equal(data.lng, -3.4900);
});

// ═════════════════════════════════════════════════════════════════════════
// TEST 2 — Sous-admin mal configuré (permissions absent ou mal typé)
// ═════════════════════════════════════════════════════════════════════════

test('TEST 2a : sous-admin actif avec permissions ABSENT — lecture refusée', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/driver-fictif-2').set({ phone: '+225 07 00 00 00 02', wallet: 100 });
    await db.doc('admins/sub-no-permissions-field').set({ role: 'sub', isActive: true });
  });
  await assertFails(asAdmin('sub-no-permissions-field').doc('livreurs/driver-fictif-2').get());
});

test('TEST 2b : sous-admin actif avec permissions MAL TYPÉ (chaîne au lieu de liste) — lecture refusée', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/driver-fictif-2b').set({ phone: '+225 07 00 00 00 03', wallet: 200 });
    await db.doc('admins/sub-bad-permissions-type').set({
      role: 'sub', isActive: true, permissions: 'livreurs',
    });
  });
  await assertFails(asAdmin('sub-bad-permissions-type').doc('livreurs/driver-fictif-2b').get());
});

// ═════════════════════════════════════════════════════════════════════════
// TEST 3 — Rôle admin invalidé
// ═════════════════════════════════════════════════════════════════════════

test('TEST 3a : compte avec isActive=true mais role="client" — lecture refusée', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/driver-fictif-3').set({ phone: '+225 07 00 00 00 04', wallet: 300 });
    await db.doc('admins/invalid-role-client').set({ role: 'client', isActive: true });
  });
  await assertFails(asAdmin('invalid-role-client').doc('livreurs/driver-fictif-3').get());
});

test('TEST 3b : compte avec isActive=true et role ABSENT — lecture refusée', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/driver-fictif-3b').set({ phone: '+225 07 00 00 00 05', wallet: 400 });
    // Document admin existant, isActive=true, mais sans champ `role` du tout.
    await db.doc('admins/missing-role-field').set({ isActive: true });
  });
  await assertFails(asAdmin('missing-role-field').doc('livreurs/driver-fictif-3b').get());
});

// ═════════════════════════════════════════════════════════════════════════
// TEST 4 — Dashboard et variations de permissions (requête non filtrée)
// ═════════════════════════════════════════════════════════════════════════
//
// LIMITATION TECHNIQUE DOCUMENTÉE : l'agrégation `.count().get()` n'est pas
// exposée par le wrapper `firestore()` de `@firebase/rules-unit-testing`
// dans cette installation (confirmé en S6.17 : `TypeError: ... .count is not
// a function`). Les 3 scénarios ci-dessous utilisent donc une requête liste
// NON FILTRÉE équivalente (`collection('livreurs').get()`), qui exerce
// exactement la même évaluation des Rules qu'un `count()` non filtré (aucune
// contrainte `where` sur un champ pertinent dans les deux cas). Je ne
// prétends PAS avoir validé l'appel `count()` lui-même, seulement
// l'évaluation de Rules sous-jacente qui le gouverne.

const dashboardScenarios = [
  { label: 'aucune permission', permissions: [] },
  { label: 'une permission sans rapport (tricycle)', permissions: ['tricycle'] },
  { label: 'plusieurs permissions sans rapport (tricycle, services, sos)', permissions: ['tricycle', 'services', 'sos'] },
];

for (const scenario of dashboardScenarios) {
  test(`TEST 4 : requête non filtrée du dashboard autorisée pour un sous-admin actif — ${scenario.label}`, async () => {
    const uid = `sub-dashboard-${scenario.label.replace(/[^a-z0-9]/gi, '')}`;
    await seed(async (db) => {
      await db.doc('livreurs/driver-fictif-4a').set({ wallet: 1, isOnline: true });
      await db.doc('livreurs/driver-fictif-4b').set({ wallet: 2, isOnline: false });
      await db.doc(`admins/${uid}`).set({ role: 'sub', isActive: true, permissions: scenario.permissions });
    });
    const snap = await assertSucceeds(asAdmin(uid).collection('livreurs').get());
    assert.equal(snap.size, 2);
  });
}

test('TEST 4 (contrôle de cohérence) : les 3 scénarios ci-dessus produisent exactement le même résultat (accès accordé, même jeu de documents)', async () => {
  await seed(async (db) => {
    await db.doc('livreurs/driver-fictif-4c').set({ wallet: 5 });
  });
  const results = [];
  for (const scenario of dashboardScenarios) {
    const uid = `sub-consistency-${scenario.label.replace(/[^a-z0-9]/gi, '')}`;
    await seed(async (db) => {
      await db.doc(`admins/${uid}`).set({ role: 'sub', isActive: true, permissions: scenario.permissions });
    });
    const snap = await assertSucceeds(asAdmin(uid).collection('livreurs').get());
    results.push(snap.size);
  }
  assert.deepEqual(results, [1, 1, 1]);
});
