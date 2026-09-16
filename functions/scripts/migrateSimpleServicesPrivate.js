'use strict';

// LOT 5.3 — séparation des données catalogue et des justificatifs privés.
//
// DRY-RUN PAR DÉFAUT :
//   node functions/scripts/migrateSimpleServicesPrivate.js
//
// Écriture réelle (commande proposée, jamais exécutée automatiquement) :
//   node functions/scripts/migrateSimpleServicesPrivate.js --apply

const EXPECTED_PROJECT_ID = 'az-express-b0469';
const MIGRATION_VERSION = 'simple_services_private_v1';
const PRIVATE_FIELDS = Object.freeze(['idNumber', 'idPhotoUrl', 'lat', 'lng']);
const PUBLIC_FIELDS = Object.freeze([
  'name', 'phone', 'serviceType', 'isAvailable', 'photoUrl',
  'createdAt', 'updatedAt',
]);

function own(data, field) {
  return Object.prototype.hasOwnProperty.call(data, field);
}

function sameValue(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function planDocument(publicData, privateData) {
  const detected = PRIVATE_FIELDS.filter((field) => own(publicData, field));
  const unknown = Object.keys(publicData)
    .filter((field) => !PUBLIC_FIELDS.includes(field) && !PRIVATE_FIELDS.includes(field));

  if (detected.length === 0) {
    return {
      outcome: privateData ? 'already_migrated' : 'clean_public',
      detected: [], unknown,
      privatePatch: {}, publicDeletes: [],
    };
  }

  const conflicts = detected.filter((field) =>
    own(privateData || {}, field) && !sameValue(privateData[field], publicData[field]));
  if (conflicts.length > 0) {
    return {
      outcome: 'conflict', detected, conflicts, unknown,
      privatePatch: {}, publicDeletes: [],
    };
  }

  const privatePatch = Object.fromEntries(
    detected.map((field) => [field, publicData[field]]),
  );
  return {
    outcome: 'needs_migration', detected, conflicts: [], unknown,
    privatePatch, publicDeletes: detected,
  };
}

function safeSummary(report) {
  return {
    dryRun: report.dryRun,
    inspected: report.inspected,
    needsMigration: report.needsMigration,
    alreadyMigrated: report.alreadyMigrated,
    cleanPublic: report.cleanPublic,
    conflicts: report.conflicts,
    anomalies: report.anomalies,
    proposedPrivateWrites: report.proposedPrivateWrites,
    proposedPublicCleanups: report.proposedPublicCleanups,
    applied: report.applied,
    errors: report.errors,
    detectedFieldCounts: report.detectedFieldCounts,
  };
}

async function runMigration({ db, admin, dryRun = true, log = console.log }) {
  const publicSnapshot = await db.collection('simple_services').get();
  const report = {
    dryRun,
    inspected: 0,
    needsMigration: 0,
    alreadyMigrated: 0,
    cleanPublic: 0,
    conflicts: 0,
    anomalies: 0,
    proposedPrivateWrites: 0,
    proposedPublicCleanups: 0,
    applied: 0,
    errors: 0,
    detectedFieldCounts: Object.fromEntries(PRIVATE_FIELDS.map((f) => [f, 0])),
  };

  for (const publicDoc of publicSnapshot.docs) {
    report.inspected++;
    const privateRef = db.collection('simple_service_private').doc(publicDoc.id);
    const privateSnapshot = await privateRef.get();
    const plan = planDocument(
      publicDoc.data(),
      privateSnapshot.exists ? privateSnapshot.data() : null,
    );
    for (const field of plan.detected) report.detectedFieldCounts[field]++;
    if (plan.unknown.length > 0) report.anomalies++;

    if (plan.outcome === 'already_migrated') {
      report.alreadyMigrated++;
      continue;
    }
    if (plan.outcome === 'clean_public') {
      report.cleanPublic++;
      continue;
    }
    if (plan.outcome === 'conflict') {
      report.conflicts++;
      continue;
    }

    report.needsMigration++;
    report.proposedPrivateWrites++;
    report.proposedPublicCleanups++;
    if (dryRun) continue;

    try {
      const now = admin.firestore.FieldValue.serverTimestamp();
      await privateRef.set({
        ...plan.privatePatch,
        migrationVersion: MIGRATION_VERSION,
        updatedAt: now,
        ...(privateSnapshot.exists ? {} : { createdAt: now }),
      }, { merge: true });

      // Vérification obligatoire avant suppression des champs publics.
      const verified = await privateRef.get();
      const copied = verified.exists && plan.detected.every(
        (field) => own(verified.data(), field)
          && sameValue(verified.data()[field], plan.privatePatch[field]),
      );
      if (!copied) {
        report.errors++;
        continue;
      }

      const deletes = Object.fromEntries(plan.publicDeletes.map(
        (field) => [field, admin.firestore.FieldValue.delete()],
      ));
      await publicDoc.ref.update({ ...deletes, updatedAt: now });
      report.applied++;
    } catch (_) {
      // Aucun identifiant ni valeur sensible dans le rapport.
      report.errors++;
    }
  }

  const summary = safeSummary(report);
  log('[migrateSimpleServicesPrivate] Rapport sécurisé :',
    JSON.stringify(summary, null, 2));
  return summary;
}

module.exports = {
  EXPECTED_PROJECT_ID,
  MIGRATION_VERSION,
  PRIVATE_FIELDS,
  PUBLIC_FIELDS,
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
  console.log(`[migrateSimpleServicesPrivate] Projet: ${projectId}; mode: ${dryRun ? 'DRY-RUN' : 'APPLY'}`);
  runMigration({ db: admin.firestore(), admin, dryRun })
    .then(() => process.exit(0))
    .catch((error) => {
      console.error('[migrateSimpleServicesPrivate] Échec sans détail sensible:',
        error && error.code ? error.code : 'unknown');
      process.exit(1);
    });
}
