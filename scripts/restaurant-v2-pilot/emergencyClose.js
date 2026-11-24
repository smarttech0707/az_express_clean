'use strict';

// Fermeture d'urgence INDÉPENDANTE du runner (Mission 7E-45). Aucun import de runStep.js, aucun fichier d'état : elle reste utilisable
// si l'état local est corrompu, si une étape a échoué, si une commande a expiré ou si le runner a été interrompu.
// Elle ne fait qu'une chose : creationOpen:false par la fonction auditée partnerOrderActionCF (super-administrateur fictif), avec la
// version RÉELLEMENT lue. Elle ne supprime jamais la configuration, ne touche jamais aux listes, n'ouvre jamais rien.
//   node scripts/restaurant-v2-pilot/emergencyClose.js --project az-express-preprod --project-number 306761725053 \
//        --credentials-dir <hors dépôt> [--execute --confirm "EMERGENCY-CLOSE t7e-lot-1 az-express-preprod 306761725053"]
// Clé API de la préproduction : variable T7E_API_KEY (jamais affichée).

const fs = require('node:fs');
const path = require('node:path');
const lot = require('./lot');
const guard = require('./guard');
const { FN, callableRequest, parseCallableResponse } = require('./firstRun');

const ADMIN_UID = lot.IDENTITIES.admin.uid;
const CONFIG_PATH = 'config/partnerOrdersV2';
const VERB = 'EMERGENCY-CLOSE';

class CloseError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// io : { project, signInAdmin() -> {uid}, readConfig() -> data|null, call(data) -> résultat de la fonction }
async function closeNow({ io, attempts = 2 }) {
  if (io.project !== undefined && io.project !== lot.TARGET.projectId) throw new CloseError('WRONG_PROJECT', 'Projet inattendu');
  const who = await io.signInAdmin();
  if (who.uid !== ADMIN_UID) throw new CloseError('WRONG_IDENTITY', 'Identité inattendue');
  const plan = lot.pilotConfigPlan().closing;
  let last = null;
  for (let i = 0; i < attempts; i += 1) {
    const live = await io.readConfig();
    if (!live) return { closed: false, nothingToClose: true };
    if (live.creationOpen !== true) return { closed: true, alreadyClosed: true, version: live.version, retried: i > 0 };
    const res = await io.call({ action: 'setPartnerOrdersConfig', patch: plan.patch, expectedVersion: live.version, reason: plan.reason });
    if (res && res.success === false) { last = res; if ((res.error || res.code) === 'CONFIG_CONFLICT') continue; throw new CloseError(res.error || 'CLOSE_REFUSED', res.message || 'Fermeture refusée'); }
    const after = await io.readConfig();
    // Contrôle minimal : fermé, version avancée, listes et mode d'accès inchangés (la fermeture ne les modifie jamais).
    if (!after || after.creationOpen !== false || !(after.version > live.version) || JSON.stringify(after.pilotPartnerIds) !== JSON.stringify(live.pilotPartnerIds)
      || JSON.stringify(after.pilotClientIds) !== JSON.stringify(live.pilotClientIds) || after.clientAccess !== live.clientAccess) {
      throw new CloseError('UNEXPECTED_STATE', 'Configuration après fermeture différente de celle prévue');
    }
    return { closed: true, version: after.version, previousVersion: live.version, retried: i > 0 };
  }
  throw new CloseError('CONFIG_CONFLICT', `Fermeture non réalisée après ${attempts} tentatives (${last && last.message})`);
}

function describe() {
  const plan = lot.pilotConfigPlan().closing;
  return {
    step: 'EMERGENCY-CLOSE', caller: 'admin', fn: FN.partner,
    request: { action: 'setPartnerOrdersConfig', patch: plan.patch, expectedVersion: '<version réellement lue>', reason: plan.reason },
    effects: ['config/partnerOrdersV2.creationOpen = false, version +1', 'audit_logs : partner_orders_config_update'],
    never: ['supprimer la configuration', 'modifier les listes', 'ouvrir le pilote', 'lire une commande'],
    stateFile: 'non utilisé',
  };
}

function cloudIo({ admin, target, credentials, apiKey, fetchImpl = fetch }) {
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Réservé à az-express-preprod');
  if (!apiKey) throw new CloseError('API_KEY_REQUIRED', 'Clé T7E_API_KEY absente');
  const c = credentials && credentials.admin;
  if (!c || !String(c.email).endsWith(`@${lot.EMAIL_DOMAIN}`)) throw new CloseError('WRONG_IDENTITY', 'Identifiants du lot absents');
  const db = admin.firestore();
  let token = null; let uri = null;
  const signIn = async () => {
    if (token) return token;
    const res = await fetchImpl(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${encodeURIComponent(apiKey)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: c.email, password: c.password, returnSecureToken: true }),
    });
    const body = await res.json();
    if (!res.ok) throw new CloseError('SIGN_IN_FAILED', `Connexion refusée (${res.status})`);
    const claims = JSON.parse(Buffer.from(body.idToken.split('.')[1], 'base64url').toString('utf8'));
    if (claims.aud !== target.projectId || claims.sub !== ADMIN_UID) throw new CloseError('WRONG_IDENTITY', 'Jeton : projet ou uid inattendu');
    token = { uid: claims.sub, idToken: body.idToken };
    return token;
  };
  const functionUri = async () => {
    if (uri) return uri;
    const { access_token: at } = await admin.credential.applicationDefault().getAccessToken();
    const res = await fetchImpl(`https://cloudfunctions.googleapis.com/v2/projects/${target.projectId}/locations/europe-west1/functions/${FN.partner}`, { headers: { Authorization: `Bearer ${at}` } });
    if (!res.ok) throw new CloseError('FUNCTION_NOT_FOUND', `Fonction introuvable (${res.status})`);
    uri = (((await res.json()).serviceConfig) || {}).uri;
    if (!/^https:\/\/[a-z0-9-]+\.a\.run\.app\/?$/.test(uri || '')) throw new CloseError('BAD_FUNCTION_URI', 'URI inattendue');
    return uri;
  };
  return {
    project: target.projectId,
    signInAdmin: async () => ({ uid: (await signIn()).uid }),
    readConfig: async () => { const s = await db.doc(CONFIG_PATH).get(); return s.exists ? s.data() : null; },
    call: async (data) => {
      const req = callableRequest(await functionUri(), (await signIn()).idToken, data);
      const res = await fetchImpl(req.url, req.init);
      const parsed = parseCallableResponse(res.status, await res.json().catch(() => null));
      if (!parsed.ok) throw new CloseError(String(parsed.status || 'CALL_FAILED'), parsed.message || 'Appel refusé');
      return parsed.result;
    },
  };
}

function parseArgs(argv) {
  const out = { flags: new Set(), values: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : null;
    if (key === 'execute') out.flags.add(key);
    else if (['project', 'project-number', 'credentials-dir', 'confirm'].includes(key)) { out.values[key] = argv[i + 1]; i += 1; } else throw new guard.GuardError('BAD_ARGUMENT', `Argument inattendu : ${argv[i]}`);
  }
  return out;
}

async function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  const args = parseArgs(argv);
  const target = guard.assertTarget({ projectId: args.values.project, projectNumber: args.values['project-number'], env });
  log(JSON.stringify({ target: { projectId: target.projectId, projectNumber: args.values['project-number'], mode: target.mode, region: 'europe-west1' }, ...describe() }, null, 2));
  if (!args.flags.has('execute')) { log('DRY-RUN : aucune connexion, aucune écriture.'); return 0; }
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Exécution réservée à az-express-preprod');
  guard.assertConfirmation(args.values.confirm, VERB);
  const credDir = guard.assertOutDirOutsideRepo(args.values['credentials-dir']);
  const prepare = require('./prepare');
  const admin = prepare.connect(target);
  await guard.verifyProjectNumberOnline({ projectId: target.projectId, fetchJson: (url) => prepare.onlineFetchJson(admin, url) });
  const io = cloudIo({ admin, target, apiKey: env.T7E_API_KEY, credentials: JSON.parse(fs.readFileSync(path.join(credDir, 'credentials.json'), 'utf8')) });
  log(JSON.stringify({ ok: true, ...(await closeNow({ io })) }, null, 2));
  return 0;
}

if (require.main === module) {
  main().then((code) => process.exit(code)).catch((err) => {
    console.error(`${err.code || 'ERREUR'} : ${String(err.message).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[jeton]').replace(/(key|token)=[^&\s"']+/gi, '$1=***')}`);
    process.exit(1);
  });
}

module.exports = { closeNow, cloudIo, describe, parseArgs, main, CloseError, VERB };
