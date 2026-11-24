'use strict';

// Mission 7E-45 — réouverture auditée, contrôle du pilote réel avant chaque étape, scénarios jour/nuit, fermeture d'urgence
// indépendante. Partie pure : interface `io` simulée en mémoire (aucun réseau, aucune écriture cloud).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const dir = path.join(__dirname, '..', '..', 'scripts', 'restaurant-v2-pilot');
const lot = require(path.join(dir, 'lot'));
const fr = require(path.join(dir, 'firstRun'));
const runner = require(path.join(dir, 'runStep'));
const emergency = require(path.join(dir, 'emergencyClose'));

const { client: CLIENT, restaurant: RESTO, admin: ADMIN } = Object.fromEntries(Object.entries(lot.IDENTITIES).map(([k, v]) => [k, v.uid]));
const UID = { client: CLIENT, restaurant: RESTO, driver: lot.IDENTITIES.driver.uid, admin: ADMIN };
const BASELINE = ['h1', 'h2', 'h3'];
const DAY = Date.UTC(2026, 10, 6, 10, 0, 0);
const NIGHT = Date.UTC(2026, 10, 6, 23, 0, 0);
// Livreurs du pilote : liste explicite fournie par la fixture (Mission 7E-55). Le runner la lit dans AZ_PILOT_DRIVER_IDS (lot.js).
const DRIVERS = ['t7e-driver'];
function withDrivers(fn) {
  const saved = process.env[lot.DRIVER_IDS_ENV];
  process.env[lot.DRIVER_IDS_ENV] = DRIVERS.join(',');
  const restore = () => { if (saved === undefined) delete process.env[lot.DRIVER_IDS_ENV]; else process.env[lot.DRIVER_IDS_ENV] = saved; };
  let out;
  try { out = fn(); } catch (e) { restore(); throw e; }
  return out && typeof out.then === 'function' ? out.finally(restore) : (restore(), out);
}
const closedConfig = (over = {}) => ({ pilotPartnerIds: [RESTO], pilotClientIds: [CLIENT], pilotDriverIds: DRIVERS, clientAccess: 'restricted', creationOpen: false, managementFrozen: false, version: 2, ...over });

// Serveur factice : applique setPartnerOrdersConfig comme la fonction réelle (version attendue, remplacement des listes).
function fakeIo(config, { wallets = { ...lot.WALLETS }, orders = BASELINE.length, quote = null } = {}) {
  const docs = new Map([['config/partnerOrdersV2', config], ['clients/' + CLIENT, { wallet: wallets.client }], ['livreurs/' + UID.driver, { wallet: wallets.driver }], ['restaurants/' + RESTO, { wallet: wallets.restaurant }]]);
  const calls = [];
  const io = {
    calls, docs,
    identity: async (role) => ({ uid: UID[role] }),
    read: async (p) => docs.get(p) || null,
    baselineOrderIds: async () => BASELINE,
    countOrders: async () => orders,
    call: async (fn, role, data) => {
      calls.push({ fn, role, data });
      if (fn === fr.FN.partner) {
        const live = docs.get('config/partnerOrdersV2');
        if (data.expectedVersion !== (live ? live.version : 0)) return { success: false, error: 'CONFIG_CONFLICT', message: 'conflit' };
        docs.set('config/partnerOrdersV2', { ...live, ...data.patch, version: live.version + 1 });
        return { success: true, data: { config: { version: live.version + 1 } } };
      }
      if (fn === fr.FN.quote) return quote;
      throw new Error(`appel inattendu ${fn}`);
    },
  };
  return io;
}
const memStore = () => { let saved = null; return { saved: () => saved, save: async (s) => { saved = JSON.stringify(s); } }; };
const staleState = () => ({ lotId: lot.LOT_ID, completed: ['S0'], configVersion: 1 });

test('réouverture depuis une configuration fermée en version 2 : version+1, listes inchangées, état mis à jour par le runner', () => withDrivers(async () => {
  const io = fakeIo(closedConfig());
  const state = staleState();
  const store = memStore();
  const res = await runner.reopenPilot({ state, io, store, expectedVersion: 2 });
  assert.deepEqual([res.reopened, res.previousVersion, res.configVersion], [true, 2, 3]);
  const cfg = io.docs.get('config/partnerOrdersV2');
  assert.deepEqual([cfg.creationOpen, cfg.version, cfg.clientAccess, cfg.pilotClientIds, cfg.pilotPartnerIds, cfg.managementFrozen], [true, 3, 'restricted', [CLIENT], [RESTO], false]);
  assert.equal(io.calls.length, 1);
  assert.deepEqual(io.calls[0].data.expectedVersion, 2);
  assert.deepEqual(io.calls[0].data, { ...lot.pilotConfigPlan().request, expectedVersion: 2 });
  assert.equal(state.configVersion, 3);
  assert.deepEqual(state.startWallets, lot.WALLETS);
  assert.equal(JSON.parse(store.saved()).configVersion, 3);
  assert.deepEqual(io.calls[0].data.patch.pilotDriverIds, DRIVERS, 'livreurs explicitement renvoyés à la réouverture');
  assert.deepEqual(cfg.pilotDriverIds, DRIVERS);
}));

test('réouverture sans liste de livreurs : bloquée avant tout appel, configuration inchangée', async () => {
  const saved = process.env[lot.DRIVER_IDS_ENV];
  delete process.env[lot.DRIVER_IDS_ENV];
  try {
    const io = fakeIo(closedConfig());
    const res = await runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: 2 }).then(() => null, (e) => e);
    assert.ok(res && res.code === 'PILOT_DRIVER_IDS_REQUIRED', String(res && res.message));
    assert.equal(io.calls.length, 0);
    assert.equal(io.docs.get('config/partnerOrdersV2').creationOpen, false);
  } finally { if (saved !== undefined) process.env[lot.DRIVER_IDS_ENV] = saved; }
});

test('réouverture : version périmée ou absente refusée avant tout appel', async () => {
  for (const v of [1, 3, 0, undefined, NaN, '2']) {
    const io = fakeIo(closedConfig());
    await assert.rejects(runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: v }), (e) => ['STALE_VERSION', 'EXPECTED_VERSION_REQUIRED'].includes(e.code), String(v));
    assert.equal(io.calls.length, 0);
  }
});

test('réouverture : liste de clients ou de partenaires différente, ouverture générale, gel, déjà ouvert, config absente → refus sans appel', async () => {
  const bad = [
    closedConfig({ pilotClientIds: [CLIENT, 'real-client'] }), closedConfig({ pilotClientIds: [] }), closedConfig({ pilotPartnerIds: [RESTO, 'real-resto'] }),
    closedConfig({ clientAccess: 'open' }), closedConfig({ managementFrozen: true }), closedConfig({ creationOpen: true }), null,
  ];
  for (const cfg of bad) {
    const io = fakeIo(cfg);
    await assert.rejects(runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: 2 }), (e) => e.code === 'PILOT_NOT_READY', JSON.stringify(cfg));
    assert.equal(io.calls.length, 0);
  }
});

test('réouverture : wallets modifiés, commande inattendue, parcours entamé ou état figé → refus', async () => {
  let io = fakeIo(closedConfig(), { wallets: { client: 33000, driver: 5000, restaurant: 0 } });
  await assert.rejects(runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: 2 }), (e) => e.code === 'WALLETS_CHANGED');
  io = fakeIo(closedConfig(), { orders: BASELINE.length + 1 });
  await assert.rejects(runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: 2 }), (e) => e.code === 'UNEXPECTED_ORDERS');
  for (const state of [{ ...staleState(), quoteId: 'q' }, { ...staleState(), orderId: 'o' }, { ...staleState(), completed: ['S0', 'S1'] }, { ...staleState(), failed: { step: 'S1' } }]) {
    io = fakeIo(closedConfig());
    await assert.rejects(runner.reopenPilot({ state, io, store: memStore(), expectedVersion: 2 }), (e) => ['JOURNEY_IN_PROGRESS', 'PREVIOUS_FAILURE'].includes(e.code));
    assert.equal(io.calls.length, 0);
  }
  io = fakeIo(closedConfig());
  io.identity = async () => ({ uid: 'real-admin' });
  await assert.rejects(runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: 2 }), (e) => e.code === 'WRONG_IDENTITY');
  io = fakeIo(closedConfig());
  io.projectId = 'az-express-b0469';
  await assert.rejects(runner.reopenPilot({ state: staleState(), io, store: memStore(), expectedVersion: 2 }), (e) => e.code === 'WRONG_PROJECT');
});

test('chaque étape relit le pilote réel : état local incohérent, config divergente ou fermée → refus avant tout appel', async () => {
  const open = (over = {}) => closedConfig({ creationOpen: true, version: 3, ...over });
  const cases = [
    [{ ...staleState(), configVersion: 1 }, open(), 'STATE_INCONSISTENT'], // S0 d'une session précédente, config réouverte en v3 par un tiers
    [{ ...staleState(), configVersion: undefined }, open(), 'STATE_INCONSISTENT'],
    [{ ...staleState(), configVersion: 3 }, open({ version: 4 }), 'STATE_INCONSISTENT'],
    [{ ...staleState(), configVersion: 3 }, closedConfig({ version: 3 }), 'PILOT_NOT_READY'],
    [{ ...staleState(), configVersion: 3 }, open({ pilotClientIds: [CLIENT, 'x'] }), 'PILOT_NOT_READY'],
    [{ ...staleState(), configVersion: 3 }, open({ clientAccess: 'open' }), 'PILOT_NOT_READY'],
    [{ ...staleState(), configVersion: 3 }, open({ pilotPartnerIds: ['real-resto'] }), 'PILOT_NOT_READY'],
    [{ ...staleState(), configVersion: 3 }, null, 'PILOT_NOT_READY'],
  ];
  for (const [state, cfg, code] of cases) {
    const io = fakeIo(cfg);
    await assert.rejects(runner.executeStep({ stepId: 'S1', state: { ...state, baselineOrderIds: BASELINE }, io, store: memStore(), nowMs: DAY }), (e) => e.code === code, `${code} ${JSON.stringify(cfg)}`);
    assert.equal(io.calls.length, 0, 'aucun appel de fonction');
  }
  // Le projet est contrôlé à chaque étape.
  const io = fakeIo(closedConfig({ creationOpen: true, version: 3 }));
  io.projectId = 'az-express-b0469';
  await assert.rejects(runner.executeStep({ stepId: 'S1', state: { ...staleState(), configVersion: 3 }, io, store: memStore(), nowMs: DAY }), (e) => e.code === 'WRONG_PROJECT');
});

test('S0 ne rouvre jamais une configuration existante : message orientant vers REOPEN', async () => {
  const io = fakeIo(closedConfig());
  await assert.rejects(runner.executeStep({ stepId: 'S0', state: { lotId: lot.LOT_ID, completed: [] }, io, store: memStore(), nowMs: DAY }), (e) => e.code === 'PILOT_ALREADY_CONFIGURED' && /REOPEN/.test(e.message));
  assert.equal(io.calls.length, 0);
});

test('tarifs : scénarios jour et nuit déduits du devis réel, commission 100 / 200, soldes attendus', () => {
  const day = lot.amountsFromQuote({ productAmount: 6500, deliveryFee: 500, isNight: false, total: 7000 });
  const night = lot.amountsFromQuote({ productAmount: 6500, deliveryFee: 1000, isNight: true, total: 7500 });
  assert.deepEqual([day.productAmount, day.deliveryFee, day.totalAmount, day.commission], [6500, 500, 7000, 100]);
  assert.deepEqual([night.productAmount, night.deliveryFee, night.totalAmount, night.commission], [6500, 1000, 7500, 200]);
  assert.deepEqual(lot.expectedLedger(day), { start: lot.WALLETS, afterCreate: { client: 33000, driver: 5000, restaurant: 0 }, afterAccept: { client: 33000, driver: 4900, restaurant: 0 }, afterDelivery: { client: 33000, driver: 5400, restaurant: 6500 } });
  assert.deepEqual(lot.expectedLedger(night), { start: lot.WALLETS, afterCreate: { client: 32500, driver: 5000, restaurant: 0 }, afterAccept: { client: 32500, driver: 4800, restaurant: 0 }, afterDelivery: { client: 32500, driver: 5800, restaurant: 6500 } });
  assert.deepEqual(lot.expectedAmounts({ nowMs: DAY }), day);
  assert.deepEqual(lot.expectedAmounts({ nowMs: NIGHT }), night);
  // Devis incohérents : frais inconnus, drapeau contradictoire, produits ou total faux.
  for (const q of [{ productAmount: 6500, deliveryFee: 700, isNight: false, total: 7200 }, { productAmount: 6500, deliveryFee: 500, isNight: true, total: 7000 }, { productAmount: 6500, deliveryFee: 1000, isNight: false, total: 7500 },
    { productAmount: 6000, deliveryFee: 500, isNight: false, total: 6500 }, { productAmount: 6500, deliveryFee: 500, isNight: false, total: 7500 }, null]) {
    assert.throws(() => lot.amountsFromQuote(q), JSON.stringify(q));
  }
});

const quoteResult = (over = {}) => ({ success: true, data: { quoteId: 'q-new', productAmount: 6500, deliveryFee: 500, total: 7000, isNight: false, ...over } });
const openedState = () => ({ lotId: lot.LOT_ID, completed: ['S0'], configVersion: 3, baselineOrderIds: BASELINE, startWallets: { ...lot.WALLETS } });
const openIo = (quote) => fakeIo(closedConfig({ creationOpen: true, version: 3 }), { quote });

test('S1 : le scénario vient du devis réel (jour ou nuit) ; jamais le tarif de jour forcé', async () => {
  let state = openedState();
  const day = await runner.executeStep({ stepId: 'S1', state, io: openIo(quoteResult()), store: memStore(), nowMs: DAY });
  assert.deepEqual([day.scenario, day.total, day.commission, state.amounts.commission], ['JOUR', 7000, 100, 100]);
  state = openedState();
  const night = await runner.executeStep({ stepId: 'S1', state, io: openIo(quoteResult({ deliveryFee: 1000, total: 7500, isNight: true })), store: memStore(), nowMs: NIGHT });
  assert.deepEqual([night.scenario, night.total, night.commission, state.quotedNight], ['NUIT', 7500, 200, true]);
  // Tarif de jour renvoyé la nuit : arrêt (jamais d'hypothèse « jour »).
  state = openedState();
  await assert.rejects(runner.executeStep({ stepId: 'S1', state, io: openIo(quoteResult()), store: memStore(), nowMs: NIGHT }), (e) => e.code === 'AMOUNT_MISMATCH');
  assert.equal(state.failed.step, 'S1');
});

test('S1 : devis antérieur 800fead3… jamais réutilisé ; wallets ou commandes inattendus bloquent', async () => {
  const state = openedState();
  await assert.rejects(runner.executeStep({ stepId: 'S1', state, io: openIo(quoteResult({ quoteId: runner.RETIRED_QUOTE_IDS[0] })), store: memStore(), nowMs: DAY }), (e) => e.code === 'RETIRED_QUOTE');
  assert.equal(state.quoteId, undefined);
  let io = fakeIo(closedConfig({ creationOpen: true, version: 3 }), { quote: quoteResult(), wallets: { client: 39500, driver: 5000, restaurant: 0 } });
  await assert.rejects(runner.executeStep({ stepId: 'S1', state: openedState(), io, store: memStore(), nowMs: DAY }), (e) => e.code === 'WALLETS_CHANGED');
  assert.equal(io.calls.length, 0);
  io = fakeIo(closedConfig({ creationOpen: true, version: 3 }), { quote: quoteResult(), orders: BASELINE.length + 1 });
  await assert.rejects(runner.executeStep({ stepId: 'S1', state: openedState(), io, store: memStore(), nowMs: DAY }), (e) => e.code === 'UNEXPECTED_ORDERS');
  assert.equal(io.calls.length, 0);
});

test('REOPEN : DRY-RUN sans réseau, production refusée, arguments inconnus (--force) refusés', () => withDrivers(async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('réseau interdit'); };
  try {
    const lines = [];
    const base = ['--project', 'az-express-preprod', '--project-number', '306761725053', '--state-dir', path.join(require('node:os').tmpdir(), 't7e-reopen-dry'), '--step', 'REOPEN', '--expected-version', '2'];
    assert.equal(await runner.main(base, {}, (l) => lines.push(l)), 0);
    assert.match(lines.join('\n'), /DRY-RUN/);
    assert.match(lines.join('\n'), /"creationOpen": true/);
    assert.match(lines.join('\n'), /"clientAccess": "restricted"/);
    await assert.rejects(runner.main(['--project', 'az-express-b0469', '--project-number', '306761725053', '--state-dir', require('node:os').tmpdir(), '--step', 'REOPEN'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(runner.main([...base, '--force'], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT');
    await assert.rejects(runner.main([...base, '--execute', '--confirm', 'RUN S0 t7e-lot-1 az-express-preprod 306761725053'], {}, () => {}), (e) => e.code === 'CONFIRMATION_REQUIRED');
  } finally { globalThis.fetch = realFetch; }
}));

// ── Fermeture d'urgence indépendante ─────────────────────────────────────────────────────────────────────────────────────────────
const emergencyIo = (config, over = {}) => {
  const docs = { config };
  const calls = [];
  return {
    project: lot.TARGET.projectId, docs, calls,
    signInAdmin: async () => ({ uid: ADMIN }),
    readConfig: async () => docs.config,
    call: async (data) => {
      calls.push(data);
      if (data.expectedVersion !== docs.config.version) return { success: false, error: 'CONFIG_CONFLICT', message: 'conflit' };
      docs.config = { ...docs.config, ...data.patch, version: docs.config.version + 1 };
      return { success: true };
    },
    ...over,
  };
};

test('fermeture d’urgence : sans fichier d’état ni runner, version réelle, listes intactes, jamais de suppression', async () => {
  assert.ok(!/runStep|first-run-state|\.unlink|\.delete\(|rmSync/.test(require('node:fs').readFileSync(path.join(dir, 'emergencyClose.js'), 'utf8').replace(/\/\/.*$/gm, '').replace(/'[^']*'/g, "''")), 'aucune dépendance au runner ni suppression');
  const io = emergencyIo(closedConfig({ creationOpen: true, version: 5 }));
  const res = await emergency.closeNow({ io });
  assert.deepEqual([res.closed, res.version, res.previousVersion], [true, 6, 5]);
  assert.deepEqual(io.calls[0], { action: 'setPartnerOrdersConfig', patch: { creationOpen: false }, expectedVersion: 5, reason: lot.pilotConfigPlan().closing.reason });
  assert.deepEqual([io.docs.config.pilotClientIds, io.docs.config.pilotPartnerIds, io.docs.config.clientAccess], [[CLIENT], [RESTO], 'restricted']);
  assert.equal((await emergency.closeNow({ io })).alreadyClosed, true, 'idempotente');
  assert.equal(io.calls.length, 1);
  assert.equal((await emergency.closeNow({ io: emergencyIo(null) })).nothingToClose, true);
});

test('fermeture d’urgence : conflit de version → relecture et nouvel essai ; échec persistant signalé ; mauvaise identité ou projet refusés', async () => {
  const io = emergencyIo(closedConfig({ creationOpen: true, version: 3 }));
  let first = true;
  const read = io.readConfig;
  io.readConfig = async () => { const c = await read(); if (first) { first = false; return { ...c, version: 2 }; } return c; }; // première lecture périmée
  const res = await emergency.closeNow({ io });
  assert.deepEqual([res.closed, res.retried, res.version], [true, true, 4]);
  const stuck = emergencyIo(closedConfig({ creationOpen: true, version: 3 }), { call: async () => ({ success: false, error: 'CONFIG_CONFLICT', message: 'x' }) });
  await assert.rejects(emergency.closeNow({ io: stuck }), (e) => e.code === 'CONFIG_CONFLICT');
  await assert.rejects(emergency.closeNow({ io: emergencyIo(closedConfig({ creationOpen: true }), { signInAdmin: async () => ({ uid: 'real-admin' }) }) }), (e) => e.code === 'WRONG_IDENTITY');
  await assert.rejects(emergency.closeNow({ io: emergencyIo(closedConfig({ creationOpen: true }), { project: 'az-express-b0469' }) }), (e) => e.code === 'WRONG_PROJECT');
  await assert.rejects(emergency.closeNow({ io: emergencyIo(closedConfig({ creationOpen: true }), { call: async () => ({ success: false, error: 'FORBIDDEN', message: 'non' }) }) }), (e) => e.code === 'FORBIDDEN');
  // Une fonction qui « réussit » sans fermer, ou qui altère les listes, est signalée.
  await assert.rejects(emergency.closeNow({ io: emergencyIo(closedConfig({ creationOpen: true }), { call: async () => ({ success: true }) }) }), (e) => e.code === 'UNEXPECTED_STATE');
});

test('fermeture d’urgence : DRY-RUN sans réseau ; production, confirmation, dossier du dépôt et arguments inconnus refusés', async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('réseau interdit'); };
  try {
    const lines = [];
    const base = ['--project', 'az-express-preprod', '--project-number', '306761725053'];
    assert.equal(await emergency.main(base, {}, (l) => lines.push(l)), 0);
    assert.match(lines.join('\n'), /DRY-RUN/);
    assert.match(lines.join('\n'), /"stateFile": "non utilisé"/);
    await assert.rejects(emergency.main(['--project', 'az-express-b0469', '--project-number', '306761725053'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(emergency.main(['--project', 'az-express-preprod', '--project-number', '1'], {}, () => {}), (e) => e.code === 'PROJECT_NUMBER_MISMATCH');
    await assert.rejects(emergency.main([...base, '--execute', '--confirm', 'RUN CLOSE t7e-lot-1 az-express-preprod 306761725053'], {}, () => {}), (e) => e.code === 'CONFIRMATION_REQUIRED');
    await assert.rejects(emergency.main([...base, '--execute', '--confirm', `${emergency.VERB} t7e-lot-1 az-express-preprod 306761725053`, '--credentials-dir', path.join(require('node:path').resolve(__dirname, '..', '..'), 'tmp')], {}, () => {}), (e) => e.code === 'OUT_DIR_IN_REPO');
    await assert.rejects(emergency.main([...base, '--force'], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT');
  } finally { globalThis.fetch = realFetch; }
});

test('fermeture d’urgence : adaptateur cloud réservé à la préproduction, clé et identifiants requis', () => {
  const target = { mode: 'preprod', projectId: 'az-express-preprod' };
  const creds = { admin: { email: 't7e-admin@example.invalid', password: 'x' } };
  assert.throws(() => emergency.cloudIo({ admin: {}, target: { mode: 'prod', projectId: 'p' }, credentials: creds, apiKey: 'k' }), (e) => e.code === 'PREPROD_ONLY');
  assert.throws(() => emergency.cloudIo({ admin: {}, target, credentials: creds }), (e) => e.code === 'API_KEY_REQUIRED');
  assert.throws(() => emergency.cloudIo({ admin: {}, target, credentials: { admin: { email: 'real@gmail.com' } }, apiKey: 'k' }), (e) => e.code === 'WRONG_IDENTITY');
});

// ── Mission 7E-46 : fermeture après création sans bloquer la commande en cours ; veille de fermeture ────────────────────────────
const watchdog = require(path.join(dir, 'closeWatchdog'));

test('pilote fermé APRÈS la création : la gestion de la commande continue (une seule fermeture auditée, version +1), pas la création', async () => {
  const live = (over) => fakeIo(closedConfig({ version: 4, ...over }));
  const base = { ...staleState(), configVersion: 3, orderId: 'ord-1' };
  const check = (stepId, io, state = base) => runner.assertLiveBeforeStep({ io, read: async (p) => io.read(p), state, stepId });
  // Ouvert à la version enregistrée, ou fermé une fois (v+1) : les étapes de gestion passent.
  for (const stepId of ['S2b', 'S3', 'S7', 'S9', 'S11']) {
    await check(stepId, live({ creationOpen: false, version: 4 }));
    await check(stepId, live({ creationOpen: true, version: 3 }));
  }
  // La création (S1, S2) exige le pilote ouvert à la version enregistrée.
  for (const stepId of ['S1', 'S2']) {
    await assert.rejects(check(stepId, live({ creationOpen: false, version: 4 })), (e) => e.code === 'PILOT_NOT_READY');
    await assert.rejects(check(stepId, live({ creationOpen: true, version: 4 })), (e) => e.code === 'STATE_INCONSISTENT');
  }
  // Fermé deux fois, rouvert par un tiers, fermé sans commande dans l'état, listes ou accès modifiés : refus.
  await assert.rejects(check('S3', live({ creationOpen: false, version: 5 })), (e) => e.code === 'STATE_INCONSISTENT');
  await assert.rejects(check('S3', live({ creationOpen: true, version: 5 })), (e) => e.code === 'STATE_INCONSISTENT');
  await assert.rejects(check('S3', live({ creationOpen: false, version: 4 }), { ...base, orderId: undefined }), (e) => e.code === 'STATE_INCONSISTENT');
  await assert.rejects(check('S3', live({ creationOpen: false, version: 4, clientAccess: 'open' })), (e) => e.code === 'PILOT_NOT_READY');
  await assert.rejects(check('S3', live({ creationOpen: false, version: 4, pilotClientIds: [CLIENT, 'x'] })), (e) => e.code === 'PILOT_NOT_READY');
  await assert.rejects(check('S3', live({ creationOpen: false, version: 4, managementFrozen: true })), (e) => e.code === 'PILOT_NOT_READY');
  await assert.rejects(check('S3', live({ creationOpen: false, version: 4 }), { ...base, configVersion: undefined }), (e) => e.code === 'STATE_INCONSISTENT');
});

test('veille de fermeture : se ferme à l’échéance, s’arrête sur le fichier stop, réessaie, échec signalé, délai maximal 30 min', async () => {
  let t = 0; const slept = [];
  const sleep = async (ms) => { slept.push(ms); t += ms; };
  const calls = [];
  const closeNow = async () => { calls.push(t); return { closed: true }; };
  // Échéance atteinte : une fermeture, jamais avant.
  let res = await watchdog.watch({ deadlineMs: 60000, now: () => t, sleep, closeNow, stopExists: () => false });
  assert.deepEqual([res.fired, res.attempts, calls.length], [true, 1, 1]);
  assert.ok(calls[0] >= 60000 && slept.every((ms) => ms <= 5000));
  // Fichier stop : aucune fermeture.
  t = 0; calls.length = 0;
  res = await watchdog.watch({ deadlineMs: 60000, now: () => t, sleep, closeNow, stopExists: () => t >= 10000 });
  assert.deepEqual([res.stopped, calls.length], [true, 0]);
  // Échecs transitoires puis succès ; échec persistant → erreur explicite.
  t = 0; let n = 0;
  res = await watchdog.watch({ deadlineMs: 1000, now: () => t, sleep, stopExists: () => false, closeNow: async () => { n += 1; if (n < 3) throw Object.assign(new Error('x'), { code: 'CALL_FAILED' }); return { closed: true }; } });
  assert.equal(res.attempts, 3);
  t = 0;
  await assert.rejects(watchdog.watch({ deadlineMs: 1000, now: () => t, sleep, stopExists: () => false, closeNow: async () => { throw Object.assign(new Error('x'), { code: 'CALL_FAILED' }); } }), (e) => e.code === 'WATCHDOG_FAILED');
  // Ligne de commande : délai borné, production refusée, confirmation, stop-file hors dépôt, aucun réseau en DRY-RUN.
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('réseau interdit'); };
  try {
    const os = require('node:os');
    const base = ['--project', 'az-express-preprod', '--project-number', '306761725053', '--stop-file', path.join(os.tmpdir(), 'stop-x'), '--max-minutes', '25'];
    const lines = [];
    assert.equal(await watchdog.main(base, {}, (l) => lines.push(l)), 0);
    assert.match(lines.join('\n'), /DRY-RUN/);
    for (const m of ['0', '31', 'abc', '']) await assert.rejects(watchdog.main([...base.slice(0, -1), m], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT', m);
    await assert.rejects(watchdog.main(['--project', 'az-express-b0469', '--project-number', '306761725053', '--stop-file', path.join(os.tmpdir(), 's'), '--max-minutes', '5'], {}, () => {}), (e) => e.code === 'PRODUCTION_FORBIDDEN');
    await assert.rejects(watchdog.main([...base, '--execute', '--confirm', 'x', '--credentials-dir', os.tmpdir()], {}, () => {}), (e) => e.code === 'CONFIRMATION_REQUIRED');
    await assert.rejects(watchdog.main([...base.slice(0, 4), '--stop-file', path.join(path.resolve(__dirname, '..', '..'), 'stop'), '--max-minutes', '5'], {}, () => {}), (e) => e.code === 'OUT_DIR_IN_REPO');
    await assert.rejects(watchdog.main([...base, '--force'], {}, () => {}), (e) => e.code === 'BAD_ARGUMENT');
  } finally { globalThis.fetch = realFetch; }
  assert.ok(!/runStep|first-run-state/.test(require('node:fs').readFileSync(path.join(dir, 'closeWatchdog.js'), 'utf8').replace(/\/\/.*$/gm, '')), 'indépendant du runner');
});
