'use strict';

/**
 * Migration locale, versionnée et réversible de `zones_livraison` vers le
 * contrat multi-ville d'Abengourou.
 *
 * Exécution depuis la racine du dépôt :
 *   node functions/scripts/migrateAbengourouZones.js
 *   node functions/scripts/migrateAbengourouZones.js --mode=dry-run
 *   node functions/scripts/migrateAbengourouZones.js --mode=apply --confirm-apply=ABENGOUROU
 *   node functions/scripts/migrateAbengourouZones.js --mode=rollback \
 *     --report=functions/scripts/reports/<rapport>.json \
 *     --confirm-rollback=ABENGOUROU
 *
 * Le mode par défaut est dry-run. Il ne crée aucun batch et n'exige que les
 * droits Firestore de lecture sur `zones_livraison`. Apply et rollback exigent
 * un compte ayant les droits d'écriture (ADC via
 * GOOGLE_APPLICATION_CREDENTIALS ou `gcloud auth application-default login`).
 *
 * Chaque exécution dry-run/apply écrit un rapport JSON horodaté dans
 * `functions/scripts/reports/`, sauf si `--report=<chemin>` est fourni. Aucun
 * rapport ni journal de migration n'est écrit dans Firestore.
 */

const fs = require('node:fs');
const path = require('node:path');

const MIGRATION_VERSION = 'abengourou_zones_v1';
const TARGET_CITY_ID = 'abengourou';
const EXPECTED_PROJECT_ID = 'az-express-b0469';
const APPLY_CONFIRMATION = 'ABENGOUROU';
const MAX_BATCH_WRITES = 400;
const MUTATED_FIELDS = [
  'cityId',
  'parentZoneId',
  'normalizedName',
  'aliases',
  'coordinateSource',
  'isServiceable',
];

function normalizeName(value) {
  if (typeof value !== 'string') return null;
  const normalized = value
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[’‘`´']/g, ' ')
    .replace(/[‐‑‒–—−-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return normalized || null;
}

function hasOwn(data, field) {
  return Object.prototype.hasOwnProperty.call(data, field);
}

function isRealLatLng(data) {
  const { lat, lng } = data;
  return typeof lat === 'number' && Number.isFinite(lat) &&
    typeof lng === 'number' && Number.isFinite(lng) &&
    lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 &&
    !(lat === 0 && lng === 0);
}

function effectiveNormalizedName(data) {
  return normalizeName(data.normalizedName) || normalizeName(data.name);
}

function findTargetCity(documents) {
  return documents.filter(({ data }) =>
    data.type === 'ville' && effectiveNormalizedName(data) === TARGET_CITY_ID);
}

function desiredPatch(document, cityDocumentId) {
  const normalizedName = effectiveNormalizedName(document.data);
  const isCity = document.id === cityDocumentId;
  const isProvenChild = !isCity &&
    normalizeName(document.data.parentName) === TARGET_CITY_ID;
  if (!isCity && !isProvenChild) return null;

  return {
    cityId: TARGET_CITY_ID,
    ...(isProvenChild ? { parentZoneId: cityDocumentId } : {}),
    normalizedName,
    aliases: [],
    coordinateSource: isCity && isRealLatLng(document.data) ? 'own' : 'unknown',
    isServiceable: false,
  };
}

function deepEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function isAlreadyConform(data, proposed) {
  return Object.entries(proposed).every(([field, value]) =>
    hasOwn(data, field) && deepEqual(data[field], value));
}

function snapshotBeforeFields(data, proposed) {
  const result = {};
  for (const field of Object.keys(proposed)) {
    result[field] = hasOwn(data, field)
      ? { present: true, value: data[field] }
      : { present: false };
  }
  return result;
}

function planMigration(documents, { generatedAt = new Date().toISOString() } = {}) {
  const targetCities = findTargetCity(documents);
  if (targetCities.length !== 1) {
    const reason = targetCities.length === 0
      ? 'Aucune ville unique ne correspond à type=ville et normalizedName=abengourou.'
      : `${targetCities.length} villes correspondent à type=ville et normalizedName=abengourou.`;
    const code = targetCities.length === 0
      ? 'TARGET_CITY_NOT_FOUND'
      : 'MULTIPLE_TARGET_CITIES';
    const entries = documents.map((document) => ({
      id: document.id,
      category: hasOwn(document.data, 'cityId') &&
        document.data.cityId !== TARGET_CITY_ID ? 'conflit' : 'autre',
      before: document.data,
      proposed: null,
      beforeFields: {},
      alreadyConform: false,
    }));
    return {
      migrationVersion: MIGRATION_VERSION,
      generatedAt,
      targetCityId: TARGET_CITY_ID,
      targetCityDocumentId: null,
      eligibleForApply: false,
      refusal: { code, message: `${reason} Migration refusée.` },
      summary: {
        total: entries.length,
        ville_cible: 0,
        enfant_prouve: 0,
        autre: entries.filter((entry) => entry.category === 'autre').length,
        conflit: entries.filter((entry) => entry.category === 'conflit').length,
        deja_conforme: 0,
        a_ecrire: 0,
      },
      documents: entries,
    };
  }

  const cityDocumentId = targetCities[0].id;
  const entries = documents.map((document) => {
    const conflict = hasOwn(document.data, 'cityId') &&
      document.data.cityId !== TARGET_CITY_ID;
    const proposed = desiredPatch(document, cityDocumentId);
    let category;
    if (conflict) category = 'conflit';
    else if (document.id === cityDocumentId) category = 'ville_cible';
    else if (proposed) category = 'enfant_prouve';
    else category = 'autre';

    return {
      id: document.id,
      category,
      before: document.data,
      proposed: conflict || category === 'autre' ? null : proposed,
      beforeFields: conflict || category === 'autre'
        ? {}
        : snapshotBeforeFields(document.data, proposed),
      alreadyConform: Boolean(proposed) && !conflict &&
        isAlreadyConform(document.data, proposed),
    };
  });

  const summary = {
    total: entries.length,
    ville_cible: entries.filter((entry) => entry.category === 'ville_cible').length,
    enfant_prouve: entries.filter((entry) => entry.category === 'enfant_prouve').length,
    autre: entries.filter((entry) => entry.category === 'autre').length,
    conflit: entries.filter((entry) => entry.category === 'conflit').length,
    deja_conforme: entries.filter((entry) => entry.alreadyConform).length,
    a_ecrire: entries.filter((entry) =>
      entry.proposed && !entry.alreadyConform).length,
  };

  return {
    migrationVersion: MIGRATION_VERSION,
    generatedAt,
    targetCityId: TARGET_CITY_ID,
    targetCityDocumentId: cityDocumentId,
    eligibleForApply: true,
    refusal: null,
    summary,
    documents: entries,
  };
}

async function loadZonesOnce(db) {
  const snapshot = await db.collection('zones_livraison').get();
  return snapshot.docs.map((doc) => ({ id: doc.id, data: doc.data() }));
}

function entriesToApply(report) {
  return report.documents.filter((entry) =>
    entry.proposed && !entry.alreadyConform && entry.category !== 'conflit');
}

async function applyReport({ db, report, maxBatchWrites = MAX_BATCH_WRITES }) {
  const pending = entriesToApply(report);
  const applied = [];
  for (let offset = 0; offset < pending.length; offset += maxBatchWrites) {
    const chunk = pending.slice(offset, offset + maxBatchWrites);
    const batch = db.batch();
    for (const entry of chunk) {
      batch.set(
        db.collection('zones_livraison').doc(entry.id),
        entry.proposed,
        { merge: true },
      );
    }
    await batch.commit();
    applied.push(...chunk.map((entry) => entry.id));
  }

  const verification = [];
  for (const entry of pending) {
    const snapshot = await db.collection('zones_livraison').doc(entry.id).get();
    const current = snapshot.exists ? snapshot.data() : null;
    const mismatches = current === null
      ? ['document_absent']
      : Object.entries(entry.proposed)
        .filter(([field, value]) => !deepEqual(current[field], value))
        .map(([field]) => field);
    verification.push({ id: entry.id, ok: mismatches.length === 0, mismatches });
  }

  const failed = verification.filter((entry) => !entry.ok);
  if (failed.length > 0) {
    const error = new Error(`Vérification post-écriture échouée pour ${failed.length} document(s).`);
    error.verification = verification;
    throw error;
  }
  return { applied, verification };
}

async function rollbackReport({ db, admin, report, maxBatchWrites = MAX_BATCH_WRITES }) {
  if (report.migrationVersion !== MIGRATION_VERSION) {
    throw new Error(`Version de rapport incompatible : ${report.migrationVersion}.`);
  }
  const candidates = report.documents.filter((entry) => entry.proposed);
  const operations = [];
  const preserved = [];

  for (const entry of candidates) {
    const ref = db.collection('zones_livraison').doc(entry.id);
    const snapshot = await ref.get();
    if (!snapshot.exists) {
      preserved.push({ id: entry.id, field: '*', reason: 'document_absent' });
      continue;
    }
    const current = snapshot.data();
    const patch = {};
    for (const field of Object.keys(entry.proposed)) {
      if (!deepEqual(current[field], entry.proposed[field])) {
        preserved.push({ id: entry.id, field, reason: 'modification_admin_posterieure' });
        continue;
      }
      const before = entry.beforeFields[field];
      patch[field] = before.present
        ? before.value
        : admin.firestore.FieldValue.delete();
    }
    if (Object.keys(patch).length > 0) operations.push({ id: entry.id, patch });
  }

  for (let offset = 0; offset < operations.length; offset += maxBatchWrites) {
    const chunk = operations.slice(offset, offset + maxBatchWrites);
    const batch = db.batch();
    for (const operation of chunk) {
      batch.set(
        db.collection('zones_livraison').doc(operation.id),
        operation.patch,
        { merge: true },
      );
    }
    await batch.commit();
  }
  return { rolledBackDocuments: operations.map((entry) => entry.id), preserved };
}

async function runMigration({
  db,
  mode = 'dry-run',
  admin = null,
  report = null,
  beforeApply = null,
}) {
  if (mode === 'rollback') {
    if (!report || !admin) throw new Error('Rollback exige un rapport et firebase-admin.');
    return { mode, rollback: await rollbackReport({ db, admin, report }), report };
  }
  if (!['dry-run', 'apply'].includes(mode)) throw new Error(`Mode inconnu : ${mode}.`);

  const documents = await loadZonesOnce(db);
  const plannedReport = planMigration(documents);
  if (mode === 'dry-run') return { mode, report: plannedReport };
  if (!plannedReport.eligibleForApply) {
    const error = new Error(plannedReport.refusal.message);
    error.code = plannedReport.refusal.code;
    throw error;
  }
  if (beforeApply) await beforeApply(plannedReport);
  const apply = await applyReport({ db, report: plannedReport });
  return { mode, report: { ...plannedReport, apply } };
}

function defaultReportPath(mode, generatedAt = new Date().toISOString()) {
  const safeTimestamp = generatedAt.replace(/[:.]/g, '-');
  return path.join(
    __dirname,
    'reports',
    `${MIGRATION_VERSION}_${mode}_${safeTimestamp}.json`,
  );
}

function writeReport(reportPath, report) {
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
}

function parseArguments(argv) {
  const valueOf = (prefix) => {
    const argument = argv.find((item) => item.startsWith(`${prefix}=`));
    return argument ? argument.slice(prefix.length + 1) : null;
  };
  return {
    mode: valueOf('--mode') || 'dry-run',
    reportPath: valueOf('--report'),
    applyConfirmation: valueOf('--confirm-apply'),
    rollbackConfirmation: valueOf('--confirm-rollback'),
  };
}

function assertCliAuthorization(args) {
  if (args.mode === 'apply' && args.applyConfirmation !== APPLY_CONFIRMATION) {
    throw new Error('APPLY refusé : ajouter --confirm-apply=ABENGOUROU.');
  }
  if (args.mode === 'rollback') {
    if (!args.reportPath) throw new Error('ROLLBACK refusé : --report est obligatoire.');
    if (args.rollbackConfirmation !== APPLY_CONFIRMATION) {
      throw new Error('ROLLBACK refusé : ajouter --confirm-rollback=ABENGOUROU.');
    }
  }
}

function printSummary(report, log = console.log) {
  log('[migrateAbengourouZones] Résumé chiffré :');
  log(JSON.stringify(report.summary, null, 2));
}

module.exports = {
  MIGRATION_VERSION,
  TARGET_CITY_ID,
  MUTATED_FIELDS,
  normalizeName,
  isRealLatLng,
  findTargetCity,
  desiredPatch,
  planMigration,
  loadZonesOnce,
  applyReport,
  rollbackReport,
  runMigration,
  defaultReportPath,
  writeReport,
  parseArguments,
  assertCliAuthorization,
  printSummary,
};

if (require.main === module) {
  (async () => {
    const args = parseArguments(process.argv.slice(2));
    assertCliAuthorization(args);

    const admin = require('firebase-admin');
    if (!admin.apps.length) admin.initializeApp({ projectId: EXPECTED_PROJECT_ID });
    const projectId = admin.app().options.projectId ||
      process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
    if (projectId !== EXPECTED_PROJECT_ID) {
      throw new Error(`Projet inattendu (${projectId}), attendu ${EXPECTED_PROJECT_ID}.`);
    }

    const db = admin.firestore();
    let sourceReport = null;
    if (args.mode === 'rollback') {
      sourceReport = JSON.parse(fs.readFileSync(args.reportPath, 'utf8'));
    }

    console.log(`[migrateAbengourouZones] Projet : ${projectId}`);
    console.log(`[migrateAbengourouZones] Mode : ${args.mode.toUpperCase()}`);
    let outputPath = null;
    const result = await runMigration({
      db,
      admin,
      mode: args.mode,
      report: sourceReport,
      beforeApply: args.mode === 'apply'
        ? async (plannedReport) => {
          outputPath = args.reportPath ||
            defaultReportPath(args.mode, plannedReport.generatedAt);
          writeReport(outputPath, {
            ...plannedReport,
            mode: args.mode,
            projectId,
            applyStatus: 'planned_before_write',
          });
          console.log(`[migrateAbengourouZones] Rapport avant écriture : ${outputPath}`);
        }
        : null,
    });

    if (args.mode === 'rollback') {
      console.log('[migrateAbengourouZones] Rollback :', JSON.stringify(result.rollback, null, 2));
      return;
    }

    outputPath = outputPath || args.reportPath ||
      defaultReportPath(args.mode, result.report.generatedAt);
    writeReport(outputPath, { ...result.report, mode: args.mode, projectId });
    printSummary(result.report);
    if (!result.report.eligibleForApply) {
      console.log(`[migrateAbengourouZones] REFUS : ${result.report.refusal.message}`);
    }
    console.log(`[migrateAbengourouZones] Rapport : ${outputPath}`);
    if (args.mode === 'dry-run') {
      console.log('[migrateAbengourouZones] DRY-RUN terminé : aucune écriture Firestore.');
    }
  })().catch((error) => {
    console.error('[migrateAbengourouZones] REFUS/ERREUR :', error.message);
    process.exitCode = 1;
  });
}
