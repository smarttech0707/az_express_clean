'use strict';

// Exécuteur PAR ÉTAPES du premier essai Restaurant v2 (Mission 7E-39). DRY-RUN par défaut ; une seule étape par appel ; l'étape
// suivante n'est jamais enchaînée automatiquement ; la première erreur fige le parcours (état « failed ») jusqu'à revue humaine.
// Le cœur (`executeStep`) ne connaît que l'interface `io` : sur l'émulateur elle appelle les modules réels de functions/, en cloud
// (`cloudIo`) elle appelle les fonctions déployées de az-express-preprod. Aucun jeton, QR ni PIN n'est jamais affiché ni journalisé ;
// l'état (qui contient le PIN/jeton de preuve, valables 15 min) est écrit hors du dépôt avec les droits 0600.
//   node scripts/restaurant-v2-pilot/runStep.js --project az-express-preprod --project-number 306761725053 \
//        --state-dir <hors dépôt> --step S3 [--execute --confirm "RUN S3 t7e-lot-1 az-express-preprod 306761725053"]

const fs = require('node:fs');
const path = require('node:path');
const lot = require('./lot');
const guard = require('./guard');
const selfie = require('./selfie');
const fr = require('./firstRun');

const { IDENTITIES } = lot;
const UID = { client: IDENTITIES.client.uid, restaurant: IDENTITIES.restaurant.uid, driver: IDENTITIES.driver.uid, admin: IDENTITIES.admin.uid };
const ORDER_OF_STEPS = Object.freeze(fr.STEPS.map((s) => s.id));
const GPS_MAX_AGE_MS = 60 * 1000; // marge de sécurité sous la limite serveur de 180 s
const WALLET_PATHS = Object.freeze({ client: `clients/${UID.client}`, driver: `livreurs/${UID.driver}`, restaurant: `restaurants/${UID.restaurant}` });

class StepError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// ── Sécurité des sorties ────────────────────────────────────────────────────────────────────────────────────────────────────────
const JWT = /eyJ[\w-]+\.[\w-]+\.[\w-]+/g;
function redact(text, state) {
  let out = String(text).replace(JWT, '[jeton]').replace(/(key|token)=[^&\s"']+/gi, '$1=***');
  const s = state && state.secrets;
  for (const v of s ? [s.pickup, s.delivery].flatMap((p) => (p ? [p.pin, p.token] : [])) : []) if (v) out = out.split(String(v)).join('[secret]');
  return out;
}

// Lecture limitée au lot : jamais une commande historique, jamais un document hors des chemins connus.
function allowedPaths(state) {
  const paths = new Set(['config/partnerOrdersV2', ...Object.values(WALLET_PATHS)]);
  if (state.orderId) paths.add(`orders/${state.orderId}`);
  if (state.quoteId) paths.add(`tariff_quotes/${state.quoteId}`);
  return paths;
}
function safeReader(io, state) {
  return async (p) => {
    if (/^orders\/(.+)$/.test(p) && (state.baselineOrderIds || []).includes(p.split('/')[1])) throw new StepError('HISTORIC_ORDER_REFUSED', 'Commande historique : lecture refusée');
    if (!allowedPaths(state).has(p)) throw new StepError('OUT_OF_LOT', `Ressource hors du lot : ${p}`);
    return io.read(p);
  };
}
// Les données envoyées ne peuvent désigner que des ressources du lot (S0 : la configuration ne liste que le restaurant fictif).
function assertDataInLot(data, state) {
  const lotUids = new Set(Object.values(UID));
  const check = (k, v) => {
    if (k === 'sellerId' && v !== UID.restaurant) throw new StepError('OUT_OF_LOT', 'sellerId hors du lot');
    if (k === 'orderId' && (v !== state.orderId || (state.baselineOrderIds || []).includes(v))) throw new StepError('OUT_OF_LOT', 'orderId hors du lot');
    if (k === 'pilotPartnerIds' && !(Array.isArray(v) && v.every((id) => id === UID.restaurant))) throw new StepError('OUT_OF_LOT', 'pilotPartnerIds hors du lot');
    if (k === 'uid' && !lotUids.has(v)) throw new StepError('OUT_OF_LOT', 'uid hors du lot');
  };
  const walk = (o) => { if (o && typeof o === 'object') for (const [k, v] of Object.entries(o)) { check(k, v); walk(v); } };
  walk(data);
}

// ── Préconditions et postconditions par étape ───────────────────────────────────────────────────────────────────────────────────
const statusIs = (o, status, sellerStatus) => !!o && o.status === status && (sellerStatus === undefined || o.sellerStatus === sellerStatus);
const GATES = {
  S0: async ({ read }) => { if (await read('config/partnerOrdersV2')) throw new StepError('PILOT_ALREADY_CONFIGURED', 'Le pilote est déjà configuré : revue manuelle'); },
  S1: async ({ read }) => {
    const c = await read('config/partnerOrdersV2');
    if (!c || c.creationOpen !== true || JSON.stringify(c.pilotPartnerIds) !== JSON.stringify([UID.restaurant])) throw new StepError('PILOT_NOT_READY', 'Pilote non ouvert au seul restaurant fictif');
  },
  S2: async ({ state }) => { if (!state.quoteId) throw new StepError('NO_QUOTE', 'Aucun devis (S1 requise)'); },
  S2b: async ({ read, state }) => { if (!statusIs(await read(`orders/${state.orderId}`), 'pending')) throw new StepError('BAD_STATE', 'Commande non « pending »'); },
  S3: async ({ read, state, clockMs }) => {
    if (!statusIs(await read(`orders/${state.orderId}`), 'pending')) throw new StepError('BAD_STATE', 'Commande non « pending »');
    const d = await read(WALLET_PATHS.driver);
    const at = d && d.updatedAt && (typeof d.updatedAt.toMillis === 'function' ? d.updatedAt.toMillis() : d.updatedAt);
    if (!at || clockMs - at > GPS_MAX_AGE_MS) throw new StepError('GPS_STALE', 'GPS du livreur périmé : lancer S2b juste avant S3');
  },
  S4: async ({ read, state }) => { if (!statusIs(await read(`orders/${state.orderId}`), 'assigned')) throw new StepError('BAD_STATE', 'Commande non « assigned »'); },
  S5: async ({ read, state }) => { if (!statusIs(await read(`orders/${state.orderId}`), 'assigned', 'preparing')) throw new StepError('BAD_STATE', 'Préparation non commencée'); },
  S6: async ({ read, state }) => { if (!statusIs(await read(`orders/${state.orderId}`), 'assigned', 'ready')) throw new StepError('BAD_STATE', 'Commande non prête'); },
  S7: async ({ read, state }) => {
    if (!state.selfieUrl) throw new StepError('NO_SELFIE', 'Selfie non déposé (S6 requise)');
    if (!statusIs(await read(`orders/${state.orderId}`), 'assigned', 'ready')) throw new StepError('BAD_STATE', 'Commande non prête');
  },
  S8: async ({ read, state }) => { if (!statusIs(await read(`orders/${state.orderId}`), 'accepted', 'ready')) throw new StepError('BAD_STATE', 'Commande non acceptée'); },
  S9: async ({ read, state }) => {
    if (!state.secrets || !state.secrets.pickup) throw new StepError('NO_PROOF', 'Preuve de récupération absente (S8 requise)');
    if (!statusIs(await read(`orders/${state.orderId}`), 'accepted', 'ready')) throw new StepError('BAD_STATE', 'Commande non acceptée');
  },
  S10: async ({ read, state }) => { if (!statusIs(await read(`orders/${state.orderId}`), 'picked_up')) throw new StepError('BAD_STATE', 'Commande non récupérée'); },
  S11: async ({ read, state }) => {
    if (!state.secrets || !state.secrets.delivery) throw new StepError('NO_PROOF', 'Preuve de livraison absente (S10 requise)');
    if (!statusIs(await read(`orders/${state.orderId}`), 'picked_up')) throw new StepError('BAD_STATE', 'Commande non récupérée');
  },
};
const AFTER = { S3: ['assigned'], S4: ['assigned', 'preparing'], S5: ['assigned', 'ready'], S7: ['accepted', 'ready'], S9: ['picked_up'], S11: ['delivered'] };
const LEDGER_AFTER = { S2: 'afterCreate', S7: 'afterAccept', S11: 'afterDelivery' };

async function readWallets(read) {
  const out = {};
  for (const [k, p] of Object.entries(WALLET_PATHS)) out[k] = (await read(p) || {}).wallet;
  return out;
}

function ctxOf(state) {
  return { orderId: state.orderId, quoteId: state.quoteId, total: state.total, selfieUrl: state.selfieUrl, pickup: (state.secrets || {}).pickup, delivery: (state.secrets || {}).delivery };
}

// ── Cœur : exécute UNE étape, vérifie, enregistre ───────────────────────────────────────────────────────────────────────────────
// nowMs : heure du barème tarifaire (jour/nuit) ; clockMs : horloge réelle, pour la fraîcheur du GPS écrit par le serveur.
async function executeStep({ stepId, state, io, store, nowMs = Date.now(), clockMs = Date.now() }) {
  const step = fr.STEPS.find((s) => s.id === stepId);
  if (!step) throw new StepError('UNKNOWN_STEP', `Étape inconnue : ${stepId}`);
  if (state.failed) throw new StepError('PREVIOUS_FAILURE', `L’étape ${state.failed.step} a échoué : revue humaine requise avant toute reprise`);
  const done = state.completed || [];
  if (done.includes(stepId)) throw new StepError('ALREADY_DONE', `${stepId} déjà exécutée (jamais rejouée automatiquement)`);
  const expectedIdx = done.length;
  if (ORDER_OF_STEPS[expectedIdx] !== stepId) throw new StepError('OUT_OF_ORDER', `Étape attendue : ${ORDER_OF_STEPS[expectedIdx] || 'aucune'}`);

  const fail = async (err) => {
    state.failed = { step: stepId, code: err.code || 'ERROR', message: redact(err.message, state).slice(0, 300) };
    await store.save(state);
    throw err;
  };
  const read = safeReader(io, state);
  try {
    if (step.caller !== 'script') {
      const who = await io.identity(step.caller);
      if (who.uid !== UID[step.caller] || !who.uid.startsWith('t7e-')) throw new StepError('WRONG_IDENTITY', 'Identité inattendue');
    }
    await GATES[stepId]({ read, state, nowMs, clockMs });
    if (stepId === 'S0') state.baselineOrderIds = (await io.baselineOrderIds());
    if (stepId === 'S0') state.startWallets = await readWallets(read);
    const data = step.data(ctxOf(state));
    if (data && step.fn) assertDataInLot(data, state);

    const summary = { step: stepId, fn: step.fn, caller: step.caller };
    if (stepId === 'S2b') await io.refreshGps();
    else if (stepId === 'S6') {
      const up = selfie.buildSelfieUpload(state.orderId);
      state.selfieUrl = await io.uploadSelfie(up);
    } else {
      const res = await io.call(step.fn, step.caller, data);
      if (res && res.success === false) throw new StepError(res.error || 'CALL_REFUSED', res.message || 'Appel refusé');
      applyResult(stepId, res, state, nowMs, summary);
    }
    await verifyAfter(stepId, { read, state, nowMs });
    state.completed = [...done, stepId];
    await store.save(state);
    return { ...summary, next: ORDER_OF_STEPS[state.completed.length] || null, wallets: state.lastWallets };
  } catch (err) {
    if (state.failed) throw err;
    return fail(err);
  }
}

function applyResult(stepId, res, state, nowMs, summary) {
  const d = (res && res.data) || {};
  if (stepId === 'S1') {
    const expected = lot.expectedAmounts({ nowMs });
    // Les frais de jour ne sont JAMAIS supposés : le total retourné doit égaler le barème officiel à l’heure de l’appel.
    if (d.total !== expected.totalAmount) throw new StepError('AMOUNT_MISMATCH', `Total du devis ${d.total}, barème attendu ${expected.totalAmount} (jour/nuit ?)`);
    state.quoteId = d.quoteId; state.total = d.total; state.amounts = expected; state.quotedNight = !!d.isNight;
    summary.total = d.total; summary.isNight = !!d.isNight;
  } else if (stepId === 'S2') {
    if (!d.orderId) throw new StepError('NO_ORDER', 'Commande non retournée');
    if ((state.baselineOrderIds || []).includes(d.orderId)) throw new StepError('HISTORIC_ORDER_REFUSED', 'Identifiant de commande historique');
    state.orderId = d.orderId; summary.orderId = d.orderId;
  } else if (stepId === 'S3') {
    if (!(d.dispatch && d.dispatch.dispatched === true)) throw new StepError('DISPATCH_FAILED', 'Aucun livreur proposé (GPS ? éligibilité ?)');
  } else if (stepId === 'S7') {
    if (res.alreadyAccepted) throw new StepError('UNEXPECTED_REPLAY', 'Acceptation déjà enregistrée avant cette étape');
  } else if (stepId === 'S8' || stepId === 'S10') {
    const proof = { pin: res.pin, token: res.token };
    if (!/^\d{6}$/.test(String(proof.pin)) || !proof.token) throw new StepError('NO_PROOF', 'Preuve non retournée');
    state.secrets = { ...(state.secrets || {}), [stepId === 'S8' ? 'pickup' : 'delivery']: proof };
  }
}

async function verifyAfter(stepId, { read, state }) {
  if (AFTER[stepId]) {
    const o = await read(`orders/${state.orderId}`);
    const [status, sellerStatus] = AFTER[stepId];
    if (!statusIs(o, status, sellerStatus)) throw new StepError('UNEXPECTED_STATE', `${stepId} : statut obtenu « ${o && o.status}/${o && o.sellerStatus} »`);
  }
  if (stepId === 'S0') {
    const c = await read('config/partnerOrdersV2');
    if (!c || c.version !== 1 || c.creationOpen !== true || JSON.stringify(c.pilotPartnerIds) !== JSON.stringify([UID.restaurant])) throw new StepError('UNEXPECTED_STATE', 'Configuration du pilote différente de celle prévue');
  }
  if (state.amounts && state.startWallets) {
    const ledger = lot.expectedLedger(state.amounts, state.startWallets);
    state.ledgerKey = LEDGER_AFTER[stepId] || state.ledgerKey;
    const wallets = await readWallets(read);
    state.lastWallets = wallets;
    const expected = state.ledgerKey ? ledger[state.ledgerKey] : ledger.start;
    if (JSON.stringify(wallets) !== JSON.stringify(expected)) throw new StepError('LEDGER_MISMATCH', `Soldes ${JSON.stringify(wallets)}, attendus ${JSON.stringify(expected)}`);
  }
}

// ── Tableau d’exécution (données de l’étape, sans effet) ────────────────────────────────────────────────────────────────────────
function describeStep(stepId, state = {}) {
  const s = fr.STEPS.find((x) => x.id === stepId);
  if (!s) throw new StepError('UNKNOWN_STEP', `Étape inconnue : ${stepId}`);
  const secret = { pin: '[secret]', token: '[secret]' };
  const ctx = { orderId: state.orderId || '<orderId>', quoteId: state.quoteId || '<quoteId>', total: state.total || '<total>', selfieUrl: state.selfieUrl || '<url>', pickup: secret, delivery: secret };
  const body = s.fn ? s.data(ctx) : null;
  return { step: s.id, title: s.title, fn: s.fn, caller: s.caller, request: s.fn ? body : s.command || { upload: 'acceptance_selfies/<orderId>/t7e-driver.jpg' }, preconditions: s.preconditions, effects: s.effects, pass: s.pass, fail: s.fail };
}

// ── Stockage de l’état (hors dépôt, droits 0600) ────────────────────────────────────────────────────────────────────────────────
function fileStore(stateDir) {
  const dir = guard.assertOutDirOutsideRepo(stateDir);
  const file = path.join(dir, 'first-run-state.json');
  return {
    file,
    load: async () => (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { lotId: lot.LOT_ID, completed: [] }),
    save: async (state) => { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(file, JSON.stringify(state, null, 2), { mode: 0o600 }); },
  };
}

// ── Adaptateur CLOUD (préproduction uniquement ; non exécuté par les tests) ─────────────────────────────────────────────────────
function cloudIo({ admin, target, credentials, manifest, apiKey, fetchImpl = fetch, log = () => {} }) {
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Adaptateur cloud réservé à az-express-preprod');
  if (!apiKey) throw new StepError('API_KEY_REQUIRED', 'Clé T7E_API_KEY absente');
  if (!manifest.project || manifest.project.id !== target.projectId || manifest.project.number !== lot.TARGET.projectNumber || manifest.lot !== lot.LOT_ID || manifest.status !== 'complete') throw new StepError('MANIFEST_MISMATCH', 'Manifeste d’un autre lot ou projet');
  const tokens = new Map();
  const uris = new Map();
  const db = admin.firestore();
  const decode = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
  const signIn = async (role) => {
    if (tokens.has(role)) return tokens.get(role);
    const c = credentials[role];
    if (!c || !String(c.email).endsWith('@example.invalid')) throw new StepError('WRONG_IDENTITY', 'Identifiants du lot absents');
    const res = await fetchImpl(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${encodeURIComponent(apiKey)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: c.email, password: c.password, returnSecureToken: true }),
    });
    const body = await res.json();
    if (!res.ok) throw new StepError('SIGN_IN_FAILED', `Connexion ${role} refusée (${res.status})`);
    const claims = decode(body.idToken);
    if (claims.aud !== target.projectId || claims.sub !== UID[role]) throw new StepError('WRONG_IDENTITY', `Jeton ${role} : projet ou uid inattendu`);
    const who = { uid: claims.sub, idToken: body.idToken };
    tokens.set(role, who);
    return who;
  };
  const functionUri = async (name) => {
    if (!uris.has(name)) {
      const { access_token: at } = await admin.credential.applicationDefault().getAccessToken();
      const res = await fetchImpl(`https://cloudfunctions.googleapis.com/v2/projects/${target.projectId}/locations/europe-west1/functions/${name}`, { headers: { Authorization: `Bearer ${at}` } });
      if (!res.ok) throw new StepError('FUNCTION_NOT_FOUND', `Fonction ${name} introuvable (${res.status})`);
      const uri = (((await res.json()).serviceConfig) || {}).uri;
      if (!/^https:\/\/[a-z0-9-]+\.a\.run\.app\/?$/.test(uri || '')) throw new StepError('BAD_FUNCTION_URI', `URI inattendue pour ${name}`);
      uris.set(name, uri);
    }
    return uris.get(name);
  };
  return {
    identity: async (role) => ({ uid: (await signIn(role)).uid }),
    call: async (fn, role, data) => {
      const { idToken } = await signIn(role);
      const req = fr.callableRequest(await functionUri(fn), idToken, data);
      const res = await fetchImpl(req.url, req.init);
      const parsed = fr.parseCallableResponse(res.status, await res.json().catch(() => null));
      if (!parsed.ok) throw Object.assign(new StepError(String(parsed.status || 'CALL_FAILED'), parsed.message || 'Appel refusé'), {});
      return parsed.result;
    },
    read: async (p) => { const s = await db.doc(p).get(); return s.exists ? s.data() : null; },
    baselineOrderIds: async () => manifest.baseline.orderIds,
    refreshGps: async () => require('./prepare').refreshDriverGps({ admin, db }),
    uploadSelfie: async (up) => {
      const { idToken } = await signIn('driver');
      const res = await fetchImpl(up.url, { method: 'POST', headers: { 'Content-Type': up.contentType, Authorization: `Firebase ${idToken}` }, body: up.bytes });
      const body = await res.json().catch(() => ({}));
      const dl = String(body.downloadTokens || '').split(',')[0];
      if (!res.ok || !dl) throw new StepError('UPLOAD_FAILED', `Dépôt du selfie refusé (${res.status})`);
      log('selfie déposé');
      return selfie.downloadUrl(up.objectPath, dl, lot.TARGET.storageBucket);
    },
  };
}

// ── Ligne de commande ────────────────────────────────────────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { flags: new Set(), values: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : null;
    if (key === 'execute') out.flags.add(key);
    else if (['project', 'project-number', 'state-dir', 'credentials-dir', 'step', 'confirm'].includes(key)) { out.values[key] = argv[i + 1]; i += 1; }
    else throw new guard.GuardError('BAD_ARGUMENT', `Argument inattendu : ${argv[i]}`);
  }
  return out;
}

async function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  const args = parseArgs(argv);
  const target = guard.assertTarget({ projectId: args.values.project, projectNumber: args.values['project-number'], env });
  const stepId = args.values.step;
  const store = fileStore(args.values['state-dir']);
  const state = await store.load();
  log(JSON.stringify(describeStep(stepId, state), null, 2));
  if (!args.flags.has('execute')) { log('DRY-RUN : aucune connexion, aucune écriture.'); return 0; }
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Exécution réservée à az-express-preprod');
  guard.assertConfirmation(args.values.confirm, `RUN ${stepId}`);
  const credDir = guard.assertOutDirOutsideRepo(args.values['credentials-dir']);
  const prepare = require('./prepare');
  const admin = prepare.connect(target);
  await guard.verifyProjectNumberOnline({ projectId: target.projectId, fetchJson: (url) => prepare.onlineFetchJson(admin, url) });
  const io = cloudIo({
    admin, target, apiKey: env.T7E_API_KEY,
    credentials: JSON.parse(fs.readFileSync(path.join(credDir, 'credentials.json'), 'utf8')),
    manifest: JSON.parse(fs.readFileSync(path.join(credDir, 'manifest.json'), 'utf8')),
  });
  const result = await executeStep({ stepId, state, io, store });
  log(JSON.stringify({ ok: true, ...result }, null, 2));
  return 0;
}

if (require.main === module) {
  main().then((code) => process.exit(code)).catch((err) => {
    console.error(`${err.code || 'ERREUR'} : ${redact(err.message)}`);
    process.exit(1);
  });
}

module.exports = { executeStep, describeStep, cloudIo, fileStore, parseArgs, main, redact, assertDataInLot, safeReader, StepError, ORDER_OF_STEPS, GPS_MAX_AGE_MS };
