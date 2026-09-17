'use strict';

// LOT 6.1 SECURITY — migration idempotente des PIN artisan historiques
// (service_providers/{id}.artisanPin, en clair) vers artisan_credentials
// (haché, CF-only). Conçu, PAS exécuté — voir le rapport LOT 6.1 pour la
// décision de lancement.
//
// DRY-RUN PAR DÉFAUT (aucune écriture, jamais le PIN/hash affiché) :
//   node functions/scripts/migrateArtisanPins.js --project=az-express-b0469
//
// Écriture réelle (commande proposée, jamais exécutée automatiquement dans
// cette session) :
//   node functions/scripts/migrateArtisanPins.js --project=az-express-b0469 --apply
//
// Idempotence : un document déjà migré (plus de champ artisanPin en clair)
// est un no-op silencieux (`outcome: 'clean'`). Ré-exécuter le script après
// une interruption (réseau, quota) ne migre jamais deux fois le même compte
// ni n'écrase un hash déjà en place.

const { hashSecret } = require('../passwordHash');

const EXPECTED_PROJECT_ID = 'az-express-b0469';
const MIGRATION_VERSION = 'artisan_pin_v1';

function own(data, field) {
  return Object.prototype.hasOwnProperty.call(data, field);
}

// Ne décide jamais du plan à partir de la VALEUR du PIN — uniquement de sa
// présence/absence et de l'existence d'un hash déjà migré. Le PIN lui-même
// ne traverse jamais cette fonction sous une forme journalisable (voir
// planDocument, qui ne renvoie jamais `plainPin` dans son résultat).
function planDocument(publicData, hasCredential) {
  const plainPin = own(publicData, 'artisanPin')
    ? String(publicData.artisanPin || '').trim()
    : '';

  if (!plainPin) {
    // Rien en clair à migrer — déjà propre, qu'un hash existe ou non
    // (ex. un artisan jamais approuvé, ou déjà migré via artisanLogin/
    // setArtisanPin, qui suppriment déjà le champ en clair eux-mêmes).
    return { outcome: 'clean', hasPlainPin: false, hasCredential };
  }

  if (hasCredential) {
    // État anormal : un hash existe déjà ET le champ en clair traîne
    // encore — ne devrait plus arriver une fois artisanLogin/setArtisanPin
    // déployés (les deux suppriment le champ en clair au moment où ils
    // écrivent le hash), mais NE JAMAIS écraser un hash existant à l'aveugle
    // ni supposer que les deux valeurs correspondent encore. Signalé pour
    // revue manuelle, jamais traité automatiquement.
    return { outcome: 'anomaly', hasPlainPin: true, hasCredential };
  }

  return { outcome: 'needs_migration', hasPlainPin: true, hasCredential };
}

function safeSummary(report) {
  return {
    dryRun: report.dryRun,
    inspected: report.inspected,
    needsMigration: report.needsMigration,
    alreadyClean: report.alreadyClean,
    anomalies: report.anomalies,
    proposedCredentialWrites: report.proposedCredentialWrites,
    proposedPlainDeletes: report.proposedPlainDeletes,
    applied: report.applied,
    errors: report.errors,
    // Volontairement aucun `documentIds`/`pin`/`hash` — même discipline que
    // migrateSimpleServicesPrivate.safeSummary (rapport diffusable sans
    // jamais exposer une donnée d'identité/secret).
  };
}

async function runMigration({ db, admin, dryRun = true, log = console.log }) {
  const providersSnapshot = await db.collection('service_providers').get();
  const report = {
    dryRun,
    inspected: 0,
    needsMigration: 0,
    alreadyClean: 0,
    anomalies: 0,
    proposedCredentialWrites: 0,
    proposedPlainDeletes: 0,
    applied: 0,
    errors: 0,
  };

  for (const providerDoc of providersSnapshot.docs) {
    report.inspected++;
    const credRef = db.collection('artisan_credentials').doc(providerDoc.id);
    const credSnap = await credRef.get();
    const plan = planDocument(providerDoc.data(), credSnap.exists);

    if (plan.outcome === 'clean') {
      report.alreadyClean++;
      continue;
    }
    if (plan.outcome === 'anomaly') {
      report.anomalies++;
      continue;
    }

    report.needsMigration++;
    report.proposedCredentialWrites++;
    report.proposedPlainDeletes++;
    if (dryRun) continue;

    try {
      // Relu juste avant écriture (pas la valeur capturée au début du
      // balayage) — réduit la fenêtre entre lecture et écriture si un
      // artisan se connecte/change son PIN pendant l'exécution du script.
      const freshSnap = await providerDoc.ref.get();
      const freshPin = String(freshSnap.data()?.artisanPin || '').trim();
      if (!freshPin) {
        // Migré entre-temps par artisanLogin/setArtisanPin (lazy) —
        // idempotent, rien à faire, pas une erreur.
        report.alreadyClean++;
        report.needsMigration--;
        report.proposedCredentialWrites--;
        report.proposedPlainDeletes--;
        continue;
      }

      const now = admin.firestore.FieldValue.serverTimestamp();
      // set() sans merge sur un doc qui ne doit pas déjà exister à ce
      // stade (hasCredential==false vérifié par planDocument) — si une
      // écriture concurrente l'a créé entre-temps, ce set écraserait un
      // hash tout juste posé par artisanLogin ; protégé par une relecture
      // immédiate avant toute suppression du champ en clair, ci-dessous.
      const alreadyCredentialed = (await credRef.get()).exists;
      if (!alreadyCredentialed) {
        await credRef.set({
          hash: hashSecret(freshPin),
          updatedAt: now,
          migratedVia: MIGRATION_VERSION,
        });
      }

      // Vérification obligatoire avant toute suppression du champ en clair.
      const verifiedCred = await credRef.get();
      if (!verifiedCred.exists || !verifiedCred.data().hash) {
        report.errors++;
        continue;
      }

      await providerDoc.ref.update({
        artisanPin: admin.firestore.FieldValue.delete(),
      });
      report.applied++;
    } catch (_) {
      // Aucun identifiant ni valeur sensible dans le rapport.
      report.errors++;
    }
  }

  const summary = safeSummary(report);
  log('[migrateArtisanPins] Rapport sécurisé :', JSON.stringify(summary, null, 2));
  return summary;
}

module.exports = {
  EXPECTED_PROJECT_ID,
  MIGRATION_VERSION,
  planDocument,
  safeSummary,
  runMigration,
};

if (require.main === module) {
  const dryRun = !process.argv.includes('--apply');
  const projectArg = process.argv.find((arg) => arg.startsWith('--project='));
  const projectId = projectArg ? projectArg.slice('--project='.length) : null;
  if (projectId !== EXPECTED_PROJECT_ID) {
    throw new Error(`Projet explicite requis; attendu: --project=${EXPECTED_PROJECT_ID}`);
  }
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp({ projectId });
  console.log(`[migrateArtisanPins] Projet: ${projectId}; mode: ${dryRun ? 'DRY-RUN' : 'APPLY'}`);
  runMigration({ db: admin.firestore(), admin, dryRun })
    .then(() => process.exit(0))
    .catch((error) => {
      console.error('[migrateArtisanPins] Échec sans détail sensible:',
        error && error.code ? error.code : 'unknown');
      process.exit(1);
    });
}
