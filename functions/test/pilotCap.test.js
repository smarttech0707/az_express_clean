// Mission 7E-9 — plafond d'instances propre à la préproduction : la production conserve ses valeurs actuelles, la préproduction
// plafonne uniquement les fonctions du pilote, la région ne change jamais. Les cas « réels » chargent index.js comme le Firebase CLI
// à l'analyse (GCLOUD_PROJECT = projet visé) et lisent __endpoint : aucun accès réseau, aucune écriture.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { pilotInstanceLimit, capInstances, pilotOnlyInstanceOptions, pilotLightOptions, pilotRetry, PREPROD_PROJECT, PILOT_LIGHT_OPTIONS } = require('../pilotCap');

const PROD = 'az-express-b0469';

test('hors préproduction : aucun plafond, valeurs d\'origine', () => {
  for (const env of [{}, { GCLOUD_PROJECT: PROD, PILOT_MAX_INSTANCES: '1' }, { GCLOUD_PROJECT: 'az-express-clean', PILOT_MAX_INSTANCES: '1' },
    { GCLOUD_PROJECT: 'az-express-preprod-1', PILOT_MAX_INSTANCES: '1' }, { GCLOUD_PROJECT: 'demo-test', PILOT_MAX_INSTANCES: '1' }]) {
    assert.equal(pilotInstanceLimit(env), null, JSON.stringify(env));
    assert.equal(capInstances(5, env), 5);
    assert.equal(capInstances(1, env), 1);
    assert.deepEqual(pilotOnlyInstanceOptions(env), {});
  }
});

test('préproduction : plafond explicite, jamais supérieur à la valeur d\'origine', () => {
  const env = { GCLOUD_PROJECT: PREPROD_PROJECT, PILOT_MAX_INSTANCES: '1' };
  assert.equal(pilotInstanceLimit(env), 1);
  assert.equal(capInstances(5, env), 1);
  assert.equal(capInstances(1, env), 1);
  assert.deepEqual(pilotOnlyInstanceOptions(env), { maxInstances: 1 });
  assert.equal(capInstances(2, { GCLOUD_PROJECT: PREPROD_PROJECT, PILOT_MAX_INSTANCES: '3' }), 2); // ne relève jamais un maximum
});

test('préproduction : variable absente ou invalide → 1 (sûr par défaut)', () => {
  for (const v of [undefined, '', 'abc', '0', '-2', '1.5', '101']) {
    const env = { GCLOUD_PROJECT: PREPROD_PROJECT, ...(v === undefined ? {} : { PILOT_MAX_INSTANCES: v }) };
    assert.equal(pilotInstanceLimit(env), 1, String(v));
  }
});

// Valeurs d'origine du code (avant 7E-9) pour les fonctions que le plafond touche.
const ORIGINAL = {
  quotePartnerOrderCF: 2, createPartnerOrderFromQuoteCF: 2, partnerOrderActionCF: 2, dispatchOrderToDriver: 3, acceptOrderCF: 5,
  deliverOrderCF: 3, cancelOrderCF: 3, releaseOrderBeforePickupCF: 2,
};
const ALREADY_ONE = ['adminOrderDisputeCF', 'adminConfirmDeliveryCF', 'autoExpireOrders', 'syncDriverOrderLifecycle'];
const PROOFS = ['prepareOrderProof', 'confirmOrderPickupWithProof', 'confirmOrderDeliveryWithProof'];
const OUT_OF_PILOT = { payOrderFromWalletCF: 3, quoteDeliveryCF: 2, createOrderFromQuoteCF: 2 };

function endpoints(project) {
  const names = [...Object.keys(ORIGINAL), ...ALREADY_ONE, ...PROOFS, ...Object.keys(OUT_OF_PILOT)];
  const code = `const m=require(${JSON.stringify(path.join(__dirname, '..', 'index.js'))});const out={};
    for(const n of ${JSON.stringify(names)}){const e=m[n]&&m[n].__endpoint;out[n]=e?{max:e.maxInstances===undefined?null:e.maxInstances,
    cpu:e.cpu===undefined?null:e.cpu,region:e.region,secrets:(e.secretEnvironmentVariables||[]).map(s=>s.key)}:null;}
    process.stdout.write('@@'+JSON.stringify(out));`;
  const env = { ...process.env, GCLOUD_PROJECT: project, FIREBASE_CONFIG: JSON.stringify({ projectId: project }), PILOT_MAX_INSTANCES: '1' };
  const out = execFileSync(process.execPath, ['-e', code], { env, encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(out.slice(out.lastIndexOf('@@') + 2));
}

test('production (analyse de index.js) : toutes les valeurs d\'origine conservées, régions inchangées', () => {
  const e = endpoints(PROD);
  for (const [n, max] of Object.entries(ORIGINAL)) assert.equal(e[n].max, max, n);
  for (const n of ALREADY_ONE) assert.equal(e[n].max, 1, n);
  for (const n of PROOFS) assert.equal(e[n].max, null, `${n} : aucun maximum posé en production (défaut plateforme inchangé)`);
  for (const [n, max] of Object.entries(OUT_OF_PILOT)) assert.equal(e[n].max, max, n);
  for (const [n, v] of Object.entries(e)) assert.deepEqual(v.region, ['europe-west1'], n);
});

test('préproduction (analyse de index.js) : fonctions du pilote à 1, hors pilote inchangées, CPU et secrets conservés', () => {
  const e = endpoints(PREPROD_PROJECT);
  for (const n of [...Object.keys(ORIGINAL), ...ALREADY_ONE, ...PROOFS]) assert.equal(e[n].max, 1, n);
  for (const [n, max] of Object.entries(OUT_OF_PILOT)) assert.equal(e[n].max, max, `${n} (hors pilote)`);
  // Le plafond ne touche ni le CPU, ni la région, ni l'accès aux secrets.
  assert.equal(e.quotePartnerOrderCF.cpu, 0.5);
  assert.equal(e.partnerOrderActionCF.cpu, 0.5);
  assert.equal(e.acceptOrderCF.cpu, null);
  for (const n of PROOFS) assert.deepEqual(e[n].secrets, ['DELIVERY_PROOF_PEPPER'], n);
  for (const [n, v] of Object.entries(e)) assert.deepEqual(v.region, ['europe-west1'], n);
});

// Mission 7E-25 : syncDriverOrderLifecycle reste sans réessai en préproduction (politique déjà déployée, sinon la CLI exige --force) ;
// la production et les autres déclencheurs conservent retry: true.
test('pilotRetry : false uniquement pour la préproduction', () => {
  assert.equal(pilotRetry(true, { GCLOUD_PROJECT: PREPROD_PROJECT }), false);
  for (const env of [{}, { GCLOUD_PROJECT: PROD }, { GCLOUD_PROJECT: 'demo-test' }, { GCLOUD_PROJECT: 'az-express-preprod-1' }]) {
    assert.equal(pilotRetry(true, env), true, JSON.stringify(env));
  }
});

function retryPolicies(project) {
  const names = ['syncDriverOrderLifecycle', 'applyDriverRatingOnOrderUpdate', 'syncPartnerQr_restaurant', 'prepareOrderProof'];
  const code = `const m=require(${JSON.stringify(path.join(__dirname, '..', 'index.js'))});const out={};
    for(const n of Object.keys(m)){const e=m[n]&&m[n].__endpoint;if(e&&e.eventTrigger)out[n]={retry:e.eventTrigger.retry,max:e.maxInstances};}
    process.stdout.write('@@'+JSON.stringify(out));`;
  const env = { ...process.env, GCLOUD_PROJECT: project, FIREBASE_CONFIG: JSON.stringify({ projectId: project }), PILOT_MAX_INSTANCES: '1' };
  const out = execFileSync(process.execPath, ['-e', code], { env, encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(out.slice(out.lastIndexOf('@@') + 2));
}

test('syncDriverOrderLifecycle : sans réessai en préproduction, retry: true en production ; les autres déclencheurs inchangés', () => {
  const prod = retryPolicies(PROD);
  const pre = retryPolicies(PREPROD_PROJECT);
  assert.equal(prod.syncDriverOrderLifecycle.retry, true);
  assert.equal(pre.syncDriverOrderLifecycle.retry, false);
  assert.equal(pre.syncDriverOrderLifecycle.max, 1);
  // Tous les autres déclencheurs : même politique dans les deux projets.
  for (const n of Object.keys(prod)) {
    if (n === 'syncDriverOrderLifecycle') continue;
    assert.equal(pre[n].retry, prod[n].retry, n);
  }
  assert.equal(prod.applyDriverRatingOnOrderUpdate.retry, true);
});

// Mission 7E-71 — fonctions de garde financières : plafond de capacité propre à la préproduction, production inchangée.
const GUARDS = ['initiateFeexPayPayment', 'initiateWithdrawal', 'aiConfirmAction', 'feexPayWebhook'];

test('pilotLightOptions : vide hors préproduction, 1 instance / 0,25 vCPU / concurrence 1 en préproduction', () => {
  for (const env of [{}, { GCLOUD_PROJECT: PROD }, { GCLOUD_PROJECT: 'az-express-clean' }, { GCLOUD_PROJECT: 'az-express-preprod-1' }, { GCLOUD_PROJECT: 'demo-test' }]) {
    assert.deepEqual(pilotLightOptions(env), {}, JSON.stringify(env));
  }
  assert.deepEqual(pilotLightOptions({ GCLOUD_PROJECT: PREPROD_PROJECT }), { maxInstances: 1, cpu: 0.25, concurrency: 1 });
  // PILOT_MAX_INSTANCES ne relève jamais ce plafond (la fraction de vCPU impose la concurrence 1).
  assert.deepEqual(pilotLightOptions({ GCLOUD_PROJECT: PREPROD_PROJECT, PILOT_MAX_INSTANCES: '50' }), { maxInstances: 1, cpu: 0.25, concurrency: 1 });
  const copy = pilotLightOptions({ GCLOUD_PROJECT: PREPROD_PROJECT });
  copy.cpu = 99; // la constante exportée n'est pas modifiable par un appelant
  assert.equal(PILOT_LIGHT_OPTIONS.cpu, 0.25);
});

function guardEndpoints(project) {
  const code = `const m=require(${JSON.stringify(path.join(__dirname, '..', 'index.js'))});const out={};
    for(const n of ${JSON.stringify(GUARDS)}){const e=m[n]&&m[n].__endpoint;out[n]=e?{max:e.maxInstances===undefined?null:e.maxInstances,
    cpu:e.cpu===undefined?null:e.cpu,conc:e.concurrency===undefined?null:e.concurrency,mem:e.availableMemoryMb===undefined?null:e.availableMemoryMb,
    timeout:e.timeoutSeconds===undefined?null:e.timeoutSeconds,region:e.region,secrets:(e.secretEnvironmentVariables||[]).map(s=>s.key).sort()}:null;}
    process.stdout.write('@@'+JSON.stringify(out));`;
  const env = { ...process.env, GCLOUD_PROJECT: project, FIREBASE_CONFIG: JSON.stringify({ projectId: project }) };
  const out = execFileSync(process.execPath, ['-e', code], { env, encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(out.slice(out.lastIndexOf('@@') + 2));
}

test('gardes financières — production : aucune option de capacité ajoutée (cpu, maxInstances, concurrence inchangés)', () => {
  const e = guardEndpoints(PROD);
  for (const n of GUARDS) {
    assert.ok(e[n], n);
    assert.equal(e[n].max, null, n);
    assert.equal(e[n].cpu, null, n);
    assert.equal(e[n].conc, null, n);
    assert.deepEqual(e[n].region, ['europe-west1'], n);
  }
  assert.equal(e.aiConfirmAction.mem, 256);
  assert.equal(e.aiConfirmAction.timeout, 60);
});

test('gardes financières — préproduction : 1 instance, 0,25 vCPU, concurrence 1 ; région, secrets, mémoire et délai conservés', () => {
  const pre = guardEndpoints(PREPROD_PROJECT);
  const prod = guardEndpoints(PROD);
  let total = 0;
  for (const n of GUARDS) {
    assert.deepEqual([pre[n].max, pre[n].cpu, pre[n].conc], [1, 0.25, 1], n);
    for (const k of ['region', 'secrets', 'mem', 'timeout']) assert.deepEqual(pre[n][k], prod[n][k], `${n}.${k}`);
    total += pre[n].cpu * pre[n].max;
  }
  assert.equal(total, 1); // empreinte théorique des quatre fonctions : 1 vCPU
});
