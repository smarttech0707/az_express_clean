'use strict';

// Dry-run by default. Never logs document IDs, PINs or credentials.
// Every account is read and, when requested, migrated in one transaction.
// No command in the LOT 7.1 validation invokes this entry point in write mode.
const { planDocument, migrateProvider } = require('../artisanCredentials');
const EXPECTED_PROJECT_ID = 'az-express-b0469';
const MIGRATION_VERSION = 'artisan_pin_v2';

function safeSummary(report) {
  return {
    dryRun: report.dryRun,
    inspected: report.inspected,
    needsMigration: report.needsMigration,
    resumable: report.resumable,
    alreadyClean: report.alreadyClean,
    anomalies: report.anomalies,
    proposedCredentialWrites: report.proposedCredentialWrites,
    proposedPlainDeletes: report.proposedPlainDeletes,
    applied: report.applied,
    errors: report.errors,
    incomplete: report.errors > 0 || report.anomalies > 0 ||
      report.applied < report.needsMigration + report.resumable,
    // Fixed counters only, never arbitrary error messages or field values.
    invalidCredentials: report.invalidCredentials,
    conflictingCredentials: report.conflictingCredentials,
    missingCredentials: report.missingCredentials,
    invalidLegacyValues: report.invalidLegacyValues,
  };
}

function migrationExitCode(report) {
  return report.errors > 0 || report.anomalies > 0 ||
    (!report.dryRun && report.incomplete) ? 2 : 0;
}

async function runMigration({ db, admin, dryRun = true, log = console.log }) {
  const providers = await db.collection('service_providers').get();
  const report = {
    dryRun, inspected: 0, needsMigration: 0, resumable: 0, alreadyClean: 0,
    anomalies: 0, proposedCredentialWrites: 0, proposedPlainDeletes: 0,
    applied: 0, errors: 0, invalidCredentials: 0, conflictingCredentials: 0,
    missingCredentials: 0, invalidLegacyValues: 0,
  };
  for (const provider of providers.docs) {
    report.inspected++;
    try {
      const plan = await migrateProvider({
        db, fieldValue: admin.firestore.FieldValue, providerId: provider.id, dryRun,
      });
      if (plan.outcome === 'clean') {
        report.alreadyClean++;
      } else if (plan.outcome === 'anomaly') {
        report.anomalies++;
        const counter = {
          invalid_credential: 'invalidCredentials', credential_mismatch: 'conflictingCredentials',
          missing_credential: 'missingCredentials', invalid_legacy: 'invalidLegacyValues',
        }[plan.reason];
        if (counter) report[counter]++;
      } else {
        if (plan.outcome === 'needs_migration') {
          report.needsMigration++;
          report.proposedCredentialWrites++;
        } else {
          report.resumable++;
        }
        report.proposedPlainDeletes++;
        if (!dryRun) report.applied++;
      }
    } catch (_) {
      report.errors++;
    }
  }
  const summary = safeSummary(report);
  log('[migrateArtisanPins]', JSON.stringify(summary));
  return summary;
}

module.exports = { EXPECTED_PROJECT_ID, MIGRATION_VERSION, planDocument, safeSummary, runMigration, migrationExitCode };

if (require.main === module) {
  const dryRun = !process.argv.includes('--apply');
  const projectArg = process.argv.find((arg) => arg.startsWith('--project='));
  const projectId = projectArg ? projectArg.slice('--project='.length) : null;
  if (projectId !== EXPECTED_PROJECT_ID) {
    throw new Error('Explicit expected project required');
  }
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp({ projectId });
  runMigration({ db: admin.firestore(), admin, dryRun })
    .then((report) => process.exit(migrationExitCode(report)))
    .catch(() => {
      console.error('[migrateArtisanPins] Incomplete: read or transaction failure');
      process.exit(1);
    });
}
