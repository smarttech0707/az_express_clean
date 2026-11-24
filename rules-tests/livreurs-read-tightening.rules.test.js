'use strict';

// SEC-01 / S6.16 — Tests ciblés sur la lecture de `livreurs`, préparant la
// fermeture étudiée en S6.15. Deux jeux de Rules sont chargés dans deux
// environnements d'émulateur SÉPARÉS :
//
//   - `testEnvCurrent`  : `firestore.rules` tel qu'il existe réellement dans
//     le dépôt (production). Documente le comportement ACTUEL (trop
//     permissif), jamais modifié par ce fichier.
//   - `testEnvCandidate` : `rules-tests/candidates/livreurs_tightened.rules`,
//     une copie intégrale de `firestore.rules` où SEULE la ligne `allow
//     read` du bloc `livreurs` a été remplacée par la proposition S6.15 §D
//     (propriétaire, super-admin, sous-admin avec permission `livreurs` /
//     `carte` / `classement` / `gains`, ou patron de flotte via `ownerId`).
//     Ce fichier candidat n'est JAMAIS copié sur `firestore.rules` et n'est
//     ni déployé ni utilisé par aucun autre test. Généré programmatiquement
//     (voir l'historique de cette phase) à partir du fichier réel, pour
//     garantir qu'aucune autre règle n'a été altérée par erreur.
//
// Exécution : `firebase emulators:exec --only firestore "node --test
// rules-tests/livreurs-read-tightening.rules.test.js"` (non ajouté au script
// npm `test:rules` existant dans cette phase, pour ne modifier que des
// fichiers de test nouveaux — voir le rapport pour la commande exacte).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');

let testEnvCurrent;
let testEnvCandidate;

test.before(async () => {
  testEnvCurrent = await initializeTestEnvironment({
    projectId: 'az-express-rules-test-livreurs-current',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
    },
  });
  testEnvCandidate = await initializeTestEnvironment({
    projectId: 'az-express-rules-test-livreurs-candidate',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, 'candidates', 'livreurs_tightened.rules'), 'utf8'),
    },
  });
});

test.after(async () => {
  await testEnvCurrent.cleanup();
  await testEnvCandidate.cleanup();
});

test.beforeEach(async () => {
  await testEnvCurrent.clearFirestore();
  await testEnvCandidate.clearFirestore();
});

// `getEnv` est appelée à CHAQUE usage (jamais capturée une fois pour toutes)
// pour lire la valeur à jour de `testEnvCurrent`/`testEnvCandidate`, assignée
// seulement dans `test.before()` — contrairement à un paramètre classique qui
// figerait `undefined` au chargement du module, avant que `test.before()` ne
// s'exécute.
function ctxFor(getEnv) {
  return {
    asClient: (uid) => getEnv().authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore(),
    asAnonymous: (uid) => getEnv().authenticatedContext(uid, { firebase: { sign_in_provider: 'anonymous' } }).firestore(),
    asAdmin: (uid) => getEnv().authenticatedContext(uid, { firebase: { sign_in_provider: 'password' } }).firestore(),
    unauth: () => getEnv().unauthenticatedContext().firestore(),
    seed: (fn) => getEnv().withSecurityRulesDisabled(async (c) => fn(c.firestore())),
  };
}

const current = ctxFor(() => testEnvCurrent);
const candidate = ctxFor(() => testEnvCandidate);

// ═════════════════════════════════════════════════════════════════════════
// 1) RULES ACTUELLES (production, inchangées) — comportement RÉEL aujourd'hui
// ═════════════════════════════════════════════════════════════════════════

test('[actuel] propriétaire : lecture de son propre document autorisée', async () => {
  await current.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true }));
  await assertSucceeds(current.asClient('d1').doc('livreurs/d1').get());
});

test('[actuel] TROUVAILLE CONNUE : un client authentifié lit un livreur qui n\'est pas le sien — succès (règle trop large, pas un idéal)', async () => {
  await current.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true }));
  await assertSucceeds(current.asClient('u-other').doc('livreurs/d1').get());
});

test('[actuel] TROUVAILLE CONNUE : un utilisateur anonyme lit un livreur quelconque — succès', async () => {
  await current.seed((db) => db.doc('livreurs/d1').set({ wallet: 500 }));
  await assertSucceeds(current.asAnonymous('anon1').doc('livreurs/d1').get());
});

test('[actuel] TROUVAILLE CONNUE : une requête liste non filtrée réussit pour n\'importe quel authentifié', async () => {
  await current.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('livreurs/d2').set({ wallet: 200 });
  });
  await assertSucceeds(current.asClient('u-other').collection('livreurs').get());
});

test('[actuel] TROUVAILLE CONNUE : un sous-admin SANS AUCUNE permission lit quand même — la permission n\'est pas vérifiée aujourd\'hui', async () => {
  await current.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('admins/sub-no-perm').set({ role: 'sub', isActive: true, permissions: [] });
  });
  await assertSucceeds(current.asAdmin('sub-no-perm').doc('livreurs/d1').get());
});

test('[actuel] écritures déjà protégées restent inchangées : le livreur ne peut pas augmenter son wallet ni se réactiver', async () => {
  await current.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isSuspended: true }));
  await assertFails(current.asClient('d1').doc('livreurs/d1').update({ wallet: 5000 }));
  await assertFails(current.asClient('d1').doc('livreurs/d1').update({ isSuspended: false }));
});

// ═════════════════════════════════════════════════════════════════════════
// 2) RULES CANDIDATES S6.15/S6.16 — jamais appliquées en production
// ═════════════════════════════════════════════════════════════════════════

// ── 2.1 Propriétaire ────────────────────────────────────────────────────────

test('[candidat] propriétaire : lecture de son propre document autorisée', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true }));
  await assertSucceeds(candidate.asClient('d1').doc('livreurs/d1').get());
});

test('[candidat] propriétaire : lecture du document d\'un AUTRE livreur refusée', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('livreurs/d2').set({ wallet: 200 });
  });
  await assertFails(candidate.asClient('d1').doc('livreurs/d2').get());
});

// ── 2.2 Utilisateurs non autorisés ──────────────────────────────────────────

test('[candidat] client authentifié ordinaire : lecture arbitraire refusée', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500 }));
  await assertFails(candidate.asClient('client-u1').doc('livreurs/d1').get());
});

test('[candidat] partenaire authentifié (ex. vendeur) : lecture arbitraire refusée', async () => {
  await candidate.seed(async (db) => {
    await db.doc('sellers/s1').set({ name: 'Boutique S1' });
    await db.doc('livreurs/d1').set({ wallet: 500 });
  });
  // Aucune branche de la règle `livreurs` ne distingue un rôle « vendeur » :
  // ce qui compte est que cet uid n'est ni propriétaire, ni admin, ni patron
  // de flotte reconnu — exactement le cas d'un compte `sellers/s1`.
  await assertFails(candidate.asClient('s1').doc('livreurs/d1').get());
});

test('[candidat] utilisateur anonyme : lecture arbitraire refusée', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500 }));
  await assertFails(candidate.asAnonymous('anon1').doc('livreurs/d1').get());
});

test('[candidat] requête liste/globale non filtrée par un utilisateur non autorisé : refusée', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('livreurs/d2').set({ wallet: 200 });
  });
  await assertFails(candidate.asClient('client-u1').collection('livreurs').get());
});

// ── 2.3 Super-admin ─────────────────────────────────────────────────────────

test('[candidat] super-admin actif : accès autorisé', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('admins/super1').set({ role: 'super', isActive: true });
  });
  await assertSucceeds(candidate.asAdmin('super1').doc('livreurs/d1').get());
});

test('[candidat] admin inactif : accès refusé même avec role=super', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('admins/inactive1').set({ role: 'super', isActive: false });
  });
  await assertFails(candidate.asAdmin('inactive1').doc('livreurs/d1').get());
});

test('[candidat] S6.17 : admin non-super SANS aucune permission liée aux livreurs reste autorisé (isActiveAdmin couvre admin_dashboard.dart, atteint par tout admin actif)', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500 });
    await db.doc('admins/sub-other').set({ role: 'sub', isActive: true, permissions: ['services'] });
  });
  await assertSucceeds(candidate.asAdmin('sub-other').doc('livreurs/d1').get());
});

test('[candidat] S6.17 : sous-admin sans aucune permission pertinente peut quand même exécuter la requête liste non filtrée de admin_dashboard.dart', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500, isOnline: true });
    await db.doc('livreurs/d2').set({ wallet: 200, isOnline: false });
    await db.doc('admins/sub-dashboard-only').set({ role: 'sub', isActive: true, permissions: ['tricycle'] });
  });
  // `.count().get()` n'est pas exposé par le wrapper firestore() de
  // @firebase/rules-unit-testing dans cette installation ; une requête liste
  // non filtrée classique exerce exactement la même évaluation des Rules
  // (même absence de `where` sur un champ pertinent) que l'agrégat utilisé
  // par admin_dashboard.dart.
  const snap = await assertSucceeds(candidate.asAdmin('sub-dashboard-only').collection('livreurs').get());
  assert.equal(snap.size, 2);
});

// ── 2.4 Sous-admins par permission réelle ───────────────────────────────────
// S6.17 : avec isActiveAdmin() dans la règle candidate, CHAQUE sous-admin actif
// est autorisé quelle que soit sa permission (voir les deux tests ci-dessus) —
// les hasAdminPermission(...) distincts de S6.15/S6.16 sont devenus redondants
// pour la LECTURE et ont été retirés de la règle candidate (toujours utilisés,
// inchangés, pour les ÉCRITURES d'autres collections, hors périmètre ici).
// Les tests suivants vérifient seulement que le statut actif reste déterminant.

for (const permission of ['livreurs', 'carte', 'classement', 'gains']) {
  test(`[candidat] sous-admin actif avec la permission '${permission}' : accès autorisé (comme tout sous-admin actif, S6.17)`, async () => {
    await candidate.seed(async (db) => {
      await db.doc('livreurs/d1').set({ wallet: 500 });
      await db.doc(`admins/sub-${permission}`).set({ role: 'sub', isActive: true, permissions: [permission] });
    });
    await assertSucceeds(candidate.asAdmin(`sub-${permission}`).doc('livreurs/d1').get());
  });

  test(`[candidat] sous-admin avec la permission '${permission}' mais INACTIF : accès refusé`, async () => {
    await candidate.seed(async (db) => {
      await db.doc('livreurs/d1').set({ wallet: 500 });
      await db.doc(`admins/sub-inactive-${permission}`).set({
        role: 'sub', isActive: false, permissions: [permission],
      });
    });
    await assertFails(candidate.asAdmin(`sub-inactive-${permission}`).doc('livreurs/d1').get());
  });
}

// ── 2.5 Flotte (relation ownerId) ───────────────────────────────────────────

test('[candidat] patron de flotte : requête where(ownerId==uid) autorisée et ne retourne que ses propres livreurs', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/mine-1').set({ wallet: 100, ownerId: 'fleet-owner-1' });
    await db.doc('livreurs/mine-2').set({ wallet: 200, ownerId: 'fleet-owner-1' });
    await db.doc('livreurs/other-1').set({ wallet: 300, ownerId: 'fleet-owner-2' });
  });
  const snap = await assertSucceeds(
    candidate.asClient('fleet-owner-1').collection('livreurs')
      .where('ownerId', '==', 'fleet-owner-1').get(),
  );
  assert.equal(snap.size, 2);
  assert.deepEqual(snap.docs.map((d) => d.id).sort(), ['mine-1', 'mine-2']);
});

test('[candidat] patron de flotte : accès direct à un livreur d\'une AUTRE flotte refusé', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/other-1').set({ wallet: 300, ownerId: 'fleet-owner-2' });
  });
  await assertFails(candidate.asClient('fleet-owner-1').doc('livreurs/other-1').get());
});

test('[candidat] patron de flotte : requête where(ownerId==<autre flotte>) refusée (ne peut pas interroger pour un ownerId qui n\'est pas le sien)', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/other-1').set({ wallet: 300, ownerId: 'fleet-owner-2' });
  });
  await assertFails(
    candidate.asClient('fleet-owner-1').collection('livreurs')
      .where('ownerId', '==', 'fleet-owner-2').get(),
  );
});

test('[candidat] patron de flotte : requête de liste NON filtrée refusée (Rules ≠ filtres — la condition ownerId exige un where correspondant)', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/mine-1').set({ wallet: 100, ownerId: 'fleet-owner-1' });
  });
  await assertFails(candidate.asClient('fleet-owner-1').collection('livreurs').get());
});

test('[candidat] livreur sans ownerId : non exposé au patron de flotte, même par accès direct', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/no-owner-1').set({ wallet: 100 });
  });
  await assertFails(candidate.asClient('fleet-owner-1').doc('livreurs/no-owner-1').get());
});

test('[candidat] relation ownerId incorrecte (uid connecté différent de la valeur ownerId) : refusée', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 100, ownerId: 'fleet-owner-1' });
  });
  await assertFails(candidate.asClient('someone-else').doc('livreurs/d1').get());
});

// ── 2.6 Non-régression écriture (le changement ne touche que `read`) ───────

test('[candidat] non-régression : le livreur ne peut toujours pas augmenter son wallet', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500 }));
  await assertFails(candidate.asClient('d1').doc('livreurs/d1').update({ wallet: 5000 }));
});

test('[candidat] non-régression : le livreur ne peut toujours pas s\'auto-réactiver (isSuspended)', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isSuspended: true }));
  await assertFails(candidate.asClient('d1').doc('livreurs/d1').update({ isSuspended: false }));
});

test('[candidat] non-régression : le livreur ne peut toujours pas changer son ownerId/ownerName', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({
    wallet: 500, ownerId: 'fleet-owner-1', ownerName: 'Flotte 1',
  }));
  await assertFails(candidate.asClient('d1').doc('livreurs/d1').update({ ownerId: 'fleet-owner-2' }));
  await assertFails(candidate.asClient('d1').doc('livreurs/d1').update({ ownerName: 'Autre flotte' }));
});

test('[candidat] non-régression : le livreur ne peut toujours pas changer deletionRequested', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, deletionRequested: false }));
  await assertFails(candidate.asClient('d1').doc('livreurs/d1').update({ deletionRequested: true }));
});

test('[candidat] non-régression : le livreur peut toujours mettre à jour sa position/isOnline (fonctionnement légitime inchangé)', async () => {
  await candidate.seed((db) => db.doc('livreurs/d1').set({ wallet: 500, isOnline: true, lat: 6.7, lng: -3.4 }));
  await assertSucceeds(candidate.asClient('d1').doc('livreurs/d1').update({ lat: 6.71, lng: -3.41, isOnline: false }));
});

test('[candidat] non-régression : un admin super conserve tous ses droits d\'écriture (suspension)', async () => {
  await candidate.seed(async (db) => {
    await db.doc('livreurs/d1').set({ wallet: 500, isSuspended: false });
    await db.doc('admins/super1').set({ role: 'super', isActive: true });
  });
  await assertSucceeds(candidate.asAdmin('super1').doc('livreurs/d1').update({ isSuspended: true }));
});

// ── 2.7 Absence d'effet sur d'autres collections ────────────────────────────

test('[candidat] driver_public (projection publique) reste inchangée — lecture par anonyme toujours autorisée', async () => {
  await candidate.seed((db) => db.doc('driver_public/d1').set({ name: 'Livreur', isOnline: true }));
  await assertSucceeds(candidate.asAnonymous('anon1').doc('driver_public/d1').get());
});

test('[candidat] admins (profil) : un admin ne lit toujours que le sien ou via isAdmin, inchangé', async () => {
  await candidate.seed(async (db) => {
    await db.doc('admins/sub1').set({ role: 'sub', isActive: true, permissions: [] });
    await db.doc('admins/sub2').set({ role: 'sub', isActive: true, permissions: [] });
  });
  await assertSucceeds(candidate.asAdmin('sub1').doc('admins/sub1').get());
  await assertFails(candidate.asAdmin('sub1').doc('admins/sub2').get());
});
