'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

// Charge index.js dans un processus séparé (aucun état partagé) et lit les métadonnées de déploiement.
function endpoints() {
  const script = `
    process.env.GCLOUD_PROJECT = 'demo-wiring'; process.env.FIREBASE_CONFIG = JSON.stringify({ projectId: 'demo-wiring' });
    const m = require('./index.js'); const out = {};
    for (const [k, v] of Object.entries(m)) if (v && v.__endpoint) { const e = v.__endpoint;
      out[k] = { region: e.region, cpu: e.cpu ?? null, max: e.maxInstances ?? null, conc: e.concurrency ?? null, secrets: e.secretEnvironmentVariables || null, retry: e.eventTrigger ? e.eventTrigger.retry : undefined, callable: !!e.callableTrigger }; }
    process.stdout.write(JSON.stringify(out));`;
  return JSON.parse(execFileSync(process.execPath, ['-e', script], { cwd: path.join(__dirname, '..'), encoding: 'utf8', maxBuffer: 1 << 24 }));
}

test('index.js exporte les deux fonctions de devis, callable, europe-west1, dimensionnées pour le quota, sans secret', () => {
  const e = endpoints();
  for (const n of ['quoteDeliveryCF', 'createOrderFromQuoteCF']) {
    assert.ok(e[n], n); assert.equal(e[n].callable, true);
    assert.deepEqual(e[n].region, ['europe-west1']);
    assert.deepEqual([e[n].cpu, e[n].max, e[n].conc, e[n].secrets], [0.5, 2, 1, null]);
  }
});

// Dépôt principal : les fonctions existantes gardent leur propre configuration (non figée ici). On vérifie seulement
// que l'ajout des deux fonctions de devis ne retire aucune fonction critique.
test('les fonctions critiques existantes restent exportées', () => {
  const e = endpoints();
  for (const n of ['acceptOrderCF', 'cancelOrderCF', 'deliverOrderCF', 'dispatchOrderToDriver', 'releaseOrderBeforePickupCF', 'syncDriverOrderLifecycle']) assert.ok(e[n], n);
});
