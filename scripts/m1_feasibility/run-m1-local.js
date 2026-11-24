'use strict';
// M1.1 — lance les émulateurs Auth + Firestore + Functions (projet fictif, ports dédiés 29xxx), exécute les tests M1 et
// M1.1 en série, arrête les émulateurs et supprime le dossier temporaire créé par CETTE exécution.
// Usage : node scripts/m1_feasibility/run-m1-local.js [--suite core|flutter|security|all] (depuis la racine du dépôt)
//         node scripts/m1_feasibility/run-m1-local.js --clean-stale   (retire les dossiers m1-local-* laissés par un arrêt brutal)
// Aucun accès distant : projet "demo-*", émulateurs uniquement. Refuse de démarrer si un port est déjà occupé
// (ne touche jamais aux émulateurs d'autres sessions).
const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '..', '..');
const PROJECT = 'demo-m1-feasibility';
const PORTS = { auth: 29199, firestore: 29080, functions: 29501, hub: 29400, logging: 29500, probeServer: 29610, probeProxy: 29611, securityProxy: 29620 };
const SUITES = {
  core: ['m1_feasibility.test.js', 'm1_1_functions.test.js', 'm1_1_firestore_rules.test.js'],
  security: ['m1_2_security.test.js'],
  flutter: ['m1_2_flutter.test.js'],
};
SUITES.all = [...SUITES.core, ...SUITES.security, ...SUITES.flutter];
const argv = process.argv.slice(2);
const suiteName = argv.includes('--suite') ? argv[argv.indexOf('--suite') + 1] : 'core';
if (!SUITES[suiteName] && !argv.includes('--clean-stale')) { console.error('Suite inconnue : ' + suiteName); process.exit(2); }
const TESTS = (SUITES[suiteName] || []).map((f) => path.join(__dirname, f));
const IS_WIN = process.platform === 'win32';

const isListening = (port) => new Promise((resolve) => {
  const s = net.connect({ host: '127.0.0.1', port });
  s.once('connect', () => { s.destroy(); resolve(true); });
  s.once('error', () => resolve(false));
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let tempDir = null;
let child = null;
let finished = false;

function killChild() {
  if (!child || child.exitCode !== null) return;
  if (IS_WIN) spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
  else child.kill('SIGTERM');
}

// Suppression SÛRE d'un dossier créé par ce lanceur ou par les tests M1.2 (m1-local-*, m1-probe-*). Garde-fous :
// parent = dossier temporaire du système (chemin réel), nom attendu, le dossier lui-même n'est pas un lien ;
// la jonction functions/node_modules (vers le dépôt) est retirée AVANT par rmdir (retire le lien seul, jamais la cible) ;
// puis aucun lien ne doit subsister dans l'arborescence avant la suppression récursive.
function hasLink(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isSymbolicLink() || fs.lstatSync(p).isSymbolicLink()) return true;
    if (e.isDirectory() && hasLink(p)) return true;
  }
  return false;
}
function removeRunDir(dir) {
  const tmpReal = fs.realpathSync(os.tmpdir());
  if (fs.lstatSync(dir).isSymbolicLink()) throw new Error('le dossier est un lien : refusé');
  const real = fs.realpathSync(dir);
  const base = path.basename(real);
  if (path.dirname(real) !== tmpReal || !/^m1-(local|probe-build|probe-chrome)-/.test(base)) throw new Error(`chemin inattendu : ${real}`);
  const link = path.join(real, 'functions', 'node_modules');
  const st = fs.lstatSync(link, { throwIfNoEntry: false });
  if (st) {
    if (!st.isSymbolicLink()) throw new Error('functions/node_modules n est pas un lien : suppression refusée');
    fs.rmdirSync(link);
  }
  if (fs.existsSync(link)) throw new Error('lien node_modules toujours présent : suppression annulée');
  if (hasLink(real)) throw new Error('un lien subsiste dans le dossier : suppression annulée');
  fs.rmSync(real, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
}

function cleanupTemp() {
  if (!tempDir) return;
  try { removeRunDir(tempDir); } catch (e) { console.error(`Nettoyage incomplet de ${tempDir} : ${e.message}`); }
  tempDir = null;
}

// Dossiers laissés par un arrêt brutal (processus tué, coupure). Ne s'exécute que si AUCUN port M1 n'est occupé ;
// un dossier m1-local-* n'est retiré que s'il porte la signature de ce lanceur (firebase.json avec Auth 29199 + prototype).
async function cleanStale() {
  for (const [name, port] of Object.entries(PORTS)) {
    if (await isListening(port)) { console.error(`Port ${name}:${port} occupé : une exécution est peut-être en cours, rien n'est supprimé.`); return 2; }
  }
  const tmpReal = fs.realpathSync(os.tmpdir());
  let removed = 0;
  for (const e of fs.readdirSync(tmpReal, { withFileTypes: true })) {
    if (!/^m1-(local|probe-chrome|probe-build)-/.test(e.name)) continue;
    const dir = path.join(tmpReal, e.name);
    try {
      if (e.name.startsWith('m1-local-')) {
        const cfg = JSON.parse(fs.readFileSync(path.join(dir, 'firebase.json'), 'utf8'));
        if (!(cfg.emulators && cfg.emulators.auth && cfg.emulators.auth.port === PORTS.auth) || !fs.existsSync(path.join(dir, 'functions', 'clientPhoneLoginPrototype.js'))) {
          console.error(`Ignoré (signature absente) : ${dir}`); continue;
        }
      }
      removeRunDir(dir); removed++; console.log(`Supprimé : ${dir}`);
    } catch (err) { console.error(`Non supprimé ${dir} : ${err.message}`); }
  }
  console.log(`${removed} dossier(s) supprimé(s).`);
  return 0;
}

async function shutdown(code) {
  if (finished) return;
  finished = true;
  killChild();
  // Laisse aux émulateurs le temps de libérer leurs ports ; ne tue rien d'autre que notre propre arbre de processus.
  for (let i = 0; i < 30; i++) {
    const busy = (await Promise.all(Object.values(PORTS).map(isListening))).some(Boolean);
    if (!busy) break;
    await sleep(500);
  }
  cleanupTemp();
  const still = [];
  for (const [name, port] of Object.entries(PORTS)) if (await isListening(port)) still.push(`${name}:${port}`);
  if (still.length) console.error(`ATTENTION : ports encore occupés après arrêt : ${still.join(', ')}`);
  process.exit(still.length && !code ? 3 : code);
}

async function main() {
  if (argv.includes('--clean-stale')) process.exit(await cleanStale());
  const busy = [];
  for (const [name, port] of Object.entries(PORTS)) if (await isListening(port)) busy.push(`${name}:${port}`);
  if (busy.length) {
    console.error(`Ports occupés (${busy.join(', ')}) : une autre session utilise peut-être ces émulateurs. Arrêt sans rien toucher.`);
    process.exit(2);
  }
  for (const f of TESTS) if (!fs.existsSync(f)) { console.error(`Fichier de test absent : ${f}`); process.exit(2); }

  tempDir = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'm1-local-'));
  const fnDir = path.join(tempDir, 'functions');
  fs.mkdirSync(fnDir);
  const src = path.join(__dirname, 'emulator', 'functions');
  fs.copyFileSync(path.join(src, 'index.js'), path.join(fnDir, 'index.js'));
  fs.copyFileSync(path.join(src, 'package.json'), path.join(fnDir, 'package.json'));
  fs.copyFileSync(path.join(__dirname, 'clientPhoneLoginPrototype.js'), path.join(fnDir, 'clientPhoneLoginPrototype.js'));
  // Dépendances en lecture seule depuis functions/node_modules du dépôt (rien n'est installé ni modifié).
  fs.symlinkSync(path.join(REPO, 'functions', 'node_modules'), path.join(fnDir, 'node_modules'), 'junction');

  const config = {
    firestore: { rules: path.join(REPO, 'firestore.rules') }, // règles RÉELLES du dépôt, lues sans modification
    functions: { source: 'functions', runtime: 'nodejs22' }, // relatif au dossier de firebase.json
    emulators: {
      auth: { host: '127.0.0.1', port: PORTS.auth },
      firestore: { host: '127.0.0.1', port: PORTS.firestore },
      functions: { host: '127.0.0.1', port: PORTS.functions },
      hub: { host: '127.0.0.1', port: PORTS.hub },
      logging: { host: '127.0.0.1', port: PORTS.logging },
      ui: { enabled: false },
      singleProjectMode: true,
    },
  };
  const configPath = path.join(tempDir, 'firebase.json');
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

  const testCmd = `node --test --test-concurrency=1 ${TESTS.map((t) => `"${t}"`).join(' ')}`;
  const cmd = `firebase emulators:exec --config "${configPath}" --project ${PROJECT} --only auth,firestore,functions "${testCmd.replace(/"/g, '\\"')}"`;
  console.log(`Émulateurs : ${Object.entries(PORTS).map(([k, v]) => `${k}=${v}`).join(' ')} | projet ${PROJECT} | temp ${tempDir}`);
  child = spawn(cmd, { cwd: tempDir, shell: true, stdio: 'inherit', env: { ...process.env, GOOGLE_APPLICATION_CREDENTIALS: '', CLOUDSDK_CONFIG: path.join(tempDir, 'no-gcloud') } });
  child.on('error', (e) => { console.error(`Lancement impossible : ${e.message}`); shutdown(1); });
  child.on('exit', (code) => shutdown(code === null ? 1 : code));
}

for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => { console.error(`\n${sig} reçu, arrêt propre…`); shutdown(130); });
process.on('uncaughtException', (e) => { console.error(e); shutdown(1); });
main().catch((e) => { console.error(e); shutdown(1); });
