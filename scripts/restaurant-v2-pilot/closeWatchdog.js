'use strict';

// Garde-fou de fermeture (Mission 7E-46) : processus SÉPARÉ du runner qui ferme le pilote à une échéance fixe, quoi qu'il arrive au
// parcours (runner interrompu, étape en échec, session terminée). Il n'importe ni runStep.js ni le fichier d'état : il appelle
// uniquement emergencyClose.closeNow (creationOpen:false par la fonction auditée, version réellement lue, jamais de suppression).
// Délai maximal de maintien du pilote ouvert : 30 minutes. Un fichier « stop » (créé après un CLOSE réussi) arrête la veille.
//   node scripts/restaurant-v2-pilot/closeWatchdog.js --project az-express-preprod --project-number 306761725053 \
//        --credentials-dir <hors dépôt> --max-minutes 25 --stop-file <hors dépôt> [--execute --confirm "WATCHDOG-CLOSE t7e-lot-1 az-express-preprod 306761725053"]
// Clé API de la préproduction : variable T7E_API_KEY (jamais affichée).

const fs = require('node:fs');
const path = require('node:path');
const guard = require('./guard');
const emergency = require('./emergencyClose');

const VERB = 'WATCHDOG-CLOSE';
const MAX_MINUTES = 30;
const POLL_MS = 5000;
const RETRY_MS = 20000;
const ATTEMPTS = 6;

// Cœur testable : horloge, attente, fermeture et fichier « stop » sont injectés.
async function watch({ deadlineMs, now = Date.now, sleep, closeNow, stopExists, log = () => {} }) {
  while (now() < deadlineMs) {
    if (stopExists()) { log('arrêt demandé : pilote déjà refermé par le parcours'); return { stopped: true }; }
    await sleep(Math.min(POLL_MS, Math.max(1, deadlineMs - now())));
  }
  if (stopExists()) return { stopped: true };
  let lastError = null;
  for (let i = 1; i <= ATTEMPTS; i += 1) {
    try {
      const res = await closeNow();
      log(`échéance atteinte : fermeture tentative ${i} → ${JSON.stringify(res)}`);
      return { fired: true, attempts: i, result: res };
    } catch (err) {
      lastError = err;
      log(`tentative ${i} en échec : ${err.code || 'ERREUR'}`);
      await sleep(RETRY_MS);
    }
  }
  throw Object.assign(new Error(`Fermeture impossible après ${ATTEMPTS} tentatives (${lastError && lastError.code})`), { code: 'WATCHDOG_FAILED' });
}

function parseArgs(argv) {
  const out = { flags: new Set(), values: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i].startsWith('--') ? argv[i].slice(2) : null;
    if (key === 'execute') out.flags.add(key);
    else if (['project', 'project-number', 'credentials-dir', 'confirm', 'max-minutes', 'stop-file'].includes(key)) { out.values[key] = argv[i + 1]; i += 1; } else throw new guard.GuardError('BAD_ARGUMENT', `Argument inattendu : ${argv[i]}`);
  }
  return out;
}

async function main(argv = process.argv.slice(2), env = process.env, log = console.log) {
  const args = parseArgs(argv);
  const target = guard.assertTarget({ projectId: args.values.project, projectNumber: args.values['project-number'], env });
  const minutes = Number(args.values['max-minutes']);
  if (!Number.isFinite(minutes) || minutes < 1 || minutes > MAX_MINUTES) throw new guard.GuardError('BAD_ARGUMENT', `--max-minutes requis, entre 1 et ${MAX_MINUTES}`);
  const stopFile = guard.assertOutDirOutsideRepo(path.dirname(path.resolve(args.values['stop-file'] || '')));
  log(JSON.stringify({ target: { projectId: target.projectId, mode: target.mode }, watchdog: { maxMinutes: minutes, stopFile: path.join(stopFile, path.basename(args.values['stop-file'])), action: emergency.describe() } }, null, 2));
  if (!args.flags.has('execute')) { log('DRY-RUN : aucune connexion, aucune écriture.'); return 0; }
  if (target.mode !== 'preprod') throw new guard.GuardError('PREPROD_ONLY', 'Exécution réservée à az-express-preprod');
  guard.assertConfirmation(args.values.confirm, VERB);
  const credDir = guard.assertOutDirOutsideRepo(args.values['credentials-dir']);
  const prepare = require('./prepare');
  const admin = prepare.connect(target);
  await guard.verifyProjectNumberOnline({ projectId: target.projectId, fetchJson: (url) => prepare.onlineFetchJson(admin, url) });
  const io = emergency.cloudIo({ admin, target, apiKey: env.T7E_API_KEY, credentials: JSON.parse(fs.readFileSync(path.join(credDir, 'credentials.json'), 'utf8')) });
  const stop = path.join(stopFile, path.basename(args.values['stop-file']));
  const deadlineMs = Date.now() + minutes * 60 * 1000;
  log(`veille démarrée ${new Date().toISOString()} ; échéance ${new Date(deadlineMs).toISOString()}`);
  const res = await watch({
    deadlineMs, sleep: (ms) => new Promise((r) => setTimeout(r, ms)), stopExists: () => fs.existsSync(stop),
    closeNow: () => emergency.closeNow({ io }), log: (m) => log(`${new Date().toISOString()} ${m}`),
  });
  log(JSON.stringify({ ok: true, ...res }));
  return 0;
}

if (require.main === module) {
  main().then((code) => process.exit(code)).catch((err) => {
    console.error(`${err.code || 'ERREUR'} : ${String(err.message).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[jeton]').replace(/(key|token)=[^&\s"']+/gi, '$1=***')}`);
    process.exit(1);
  });
}

module.exports = { watch, parseArgs, main, VERB, MAX_MINUTES };
