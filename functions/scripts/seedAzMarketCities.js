'use strict';

// Default mode is dry-run. This script never enables delivery serviceability.
const fs = require('node:fs');
const path = require('node:path');

const PROJECT_ID = 'az-express-b0469';
const CONFIRMATION = 'AZ_MARKET_CI';
const CITIES = require('./data/az_market_initial_cities.json');

function planSeed(documents) {
  const existing = new Map();
  for (const document of documents) {
    const cityId = document.data.cityId;
    if (document.data.type === 'ville' && typeof cityId === 'string') {
      existing.set(cityId, document);
    }
  }
  return CITIES.map(([cityId, name], order) => {
    const current = existing.get(cityId);
    if (current) {
      return {
        cityId,
        documentId: current.id,
        operation: current.data.isMarketplaceEnabled === true ? 'unchanged' : 'update',
        patch: current.data.isMarketplaceEnabled === true
          ? null
          : { isMarketplaceEnabled: true },
      };
    }
    return {
      cityId,
      documentId: `market-city-${cityId}`,
      operation: 'create',
      patch: {
        name,
        type: 'ville',
        cityId,
        normalizedName: cityId,
        aliases: [],
        coordinateSource: 'unknown',
        isServiceable: false,
        isActive: false,
        isMarketplaceEnabled: true,
        order,
      },
    };
  });
}

async function loadDocuments(db) {
  const snapshot = await db.collection('zones_livraison').get();
  return snapshot.docs.map((document) => ({ id: document.id, data: document.data() }));
}

async function applyPlan(db, plan) {
  const actionable = plan.filter((entry) => entry.patch);
  for (let offset = 0; offset < actionable.length; offset += 400) {
    const batch = db.batch();
    for (const entry of actionable.slice(offset, offset + 400)) {
      batch.set(db.collection('zones_livraison').doc(entry.documentId), entry.patch,
        { merge: true });
    }
    await batch.commit();
  }
  return actionable.length;
}

function parseArguments(argv) {
  return {
    mode: argv.includes('--apply') ? 'apply' : 'dry-run',
    confirmation: argv.find((value) => value.startsWith('--confirm='))?.slice(10),
  };
}

module.exports = { CITIES, planSeed, applyPlan, parseArguments };

if (require.main === module) {
  (async () => {
    const args = parseArguments(process.argv.slice(2));
    if (args.mode === 'apply' && args.confirmation !== CONFIRMATION) {
      throw new Error('Apply refused: use --confirm=AZ_MARKET_CI.');
    }
    const admin = require('firebase-admin');
    if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT_ID });
    if (admin.app().options.projectId !== PROJECT_ID) {
      throw new Error('Unexpected Firebase project.');
    }
    const plan = planSeed(await loadDocuments(admin.firestore()));
    console.log(JSON.stringify({
      mode: args.mode,
      total: plan.length,
      create: plan.filter((entry) => entry.operation === 'create').length,
      update: plan.filter((entry) => entry.operation === 'update').length,
      unchanged: plan.filter((entry) => entry.operation === 'unchanged').length,
    }));
    if (args.mode === 'apply') await applyPlan(admin.firestore(), plan);
  })().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
