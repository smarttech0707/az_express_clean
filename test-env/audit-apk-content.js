'use strict';

// Audit du contenu d'un APK de test DEJA EXTRAIT dans un dossier : references de production, cles API embarquees, URLs.
// Usage : node test-env/audit-apk-content.js <dossier-extrait> <cle-api-android-de-test-attendue (google-services.json)> [fichier-cle-maps-de-test]
// Les cles ne sont jamais affichees en clair (4 derniers caracteres seulement). Code retour 1 si une reference de production
// ou une cle API inattendue est trouvee.
//
// Le 3e argument (optionnel) est le chemin d'un fichier contenant la seule cle Google Maps CLIENTE de test
// autorisee (TEST_MAPS_API_KEY), jamais passee en ligne de commande. Absent ou vide : aucune cle Maps de test
// n'est attendue (ex. build --maps-disabled) et seules les cles Firebase + la cle factice d'emulateur sont connues.
// La cle serveur GOOGLE_MAPS_SERVER_KEY n'est jamais lue ici et n'est donc jamais une cle cliente autorisee.
const fs = require('fs');
const path = require('path');
const g = require('./lib/guards');

const KEY_RE = /AIza[0-9A-Za-z_-]{35}/;
const mask = (k) => `AIza…${k.slice(-4)}`;

// Renvoie { testKey: string[], mapsKey: string|null }. Leve si le fichier de cle Maps de test est illisible ou
// contient une valeur qui n'a pas la forme d'une cle API Google (echec ferme : jamais une valeur ignoree en silence).
function loadAuthorizedKeys(googleServices, testMapsKeyFile) {
  const testKey = (JSON.parse(fs.readFileSync(googleServices, 'utf8')).client || [])
    .flatMap((c) => (c.api_key || []).map((k) => k.current_key));
  // Cle factice de l'emulateur (lib/services/firebase_emulator_config.dart) : non secrete, ne designe aucun projet reel.
  const emu = KEY_RE.exec(fs.readFileSync(path.resolve(__dirname, '..', 'lib/services/firebase_emulator_config.dart'), 'utf8'));
  if (emu) testKey.push(emu[0]);
  let mapsKey = null;
  if (testMapsKeyFile) {
    const raw = fs.readFileSync(testMapsKeyFile, 'utf8').trim();
    if (raw) {
      if (!new RegExp(`^${KEY_RE.source}$`).test(raw)) {
        throw new Error('REFUS : la cle Maps de test fournie n\'a pas la forme d\'une cle API Google valide.');
      }
      mapsKey = raw;
    }
  }
  return { testKey, mapsKey };
}

// Classe une cle trouvee dans l'APK. Jamais la cle de production (non lue par ce script), jamais la cle serveur
// GOOGLE_MAPS_SERVER_KEY (non lue par ce script) : seules les cles Firebase de test et la cle Maps de test exacte
// (comparaison stricte, pas un prefixe) sont reconnues.
function labelKey(key, { testKey, mapsKey }) {
  if (mapsKey !== null && key === mapsKey) return 'cle Maps de TEST (attendue)';
  if (testKey.includes(key)) return 'cle Firebase de TEST (attendue)';
  return null;
}

function* walk(p) {
  for (const e of fs.readdirSync(p, { withFileTypes: true })) {
    const f = path.join(p, e.name);
    if (e.isDirectory()) yield* walk(f); else yield f;
  }
}

// Parcourt `dir` et renvoie le rapport d'audit (aucune cle en clair : seulement masquee ou en Set/Map de hits).
function auditDirectory(dir, authorizedKeys) {
  const PUBLIC_WEB = 'az-express-b0469.web.app';
  const urlRe = /https?:\/\/[A-Za-z0-9._-]+(?:\.[A-Za-z]{2,})/g;
  const keyHits = new Map();
  const prodHits = new Map();
  const hosts = new Map();
  const webHits = new Set();

  for (const f of walk(dir)) {
    const data = fs.readFileSync(f);
    // Les .so/.dex/.arsc/manifeste melangent UTF-8 et UTF-16 : on analyse les deux decodages.
    for (const text of [data.toString('latin1'), data.toString('utf16le')]) {
      for (const k of text.match(new RegExp(KEY_RE.source, 'g')) || []) {
        const rel = path.relative(dir, f);
        if (!keyHits.has(k)) keyHits.set(k, new Set());
        keyHits.get(k).add(rel);
      }
      const publicOnly = text.split(PUBLIC_WEB).join('');
      if (text.includes(PUBLIC_WEB)) { const rel = path.relative(dir, f); if (!webHits.has(rel)) webHits.add(rel); }
      for (const h of g.findProductionReferences(publicOnly)) {
        const rel = path.relative(dir, f);
        if (!prodHits.has(h)) prodHits.set(h, new Set());
        prodHits.get(h).add(rel);
      }
      for (const u of text.match(urlRe) || []) {
        const host = u.replace(/^https?:\/\//, '').toLowerCase();
        hosts.set(host, (hosts.get(host) || 0) + 1);
      }
    }
  }

  let bad = 0;
  const unknownKeys = [];
  for (const [k, files] of keyHits) {
    const label = labelKey(k, authorizedKeys);
    if (!label) { bad++; unknownKeys.push(k); }
  }
  if (prodHits.size) bad += prodHits.size;
  return { keyHits, prodHits, hosts, webHits, unknownKeys, bad };
}

function printReport({ keyHits, prodHits, hosts, webHits }, authorizedKeys) {
  const PUBLIC_WEB = 'az-express-b0469.web.app';
  console.log('--- Cles API embarquees (masquees)');
  for (const [k, files] of keyHits) {
    const label = labelKey(k, authorizedKeys) || 'INCONNUE / a examiner';
    console.log(` ${mask(k)} : ${label} dans ${[...files].slice(0, 3).join(', ')}`);
  }
  if (!keyHits.size) console.log(' aucune');
  console.log('--- References de production');
  for (const [h, files] of prodHits) { console.log(` « ${h} » dans ${[...files].slice(0, 3).join(', ')}`); }
  if (!prodHits.size) console.log(' aucune');
  console.log('--- Pages web publiques de production referencees (avertissement, pas une connexion de donnees)');
  console.log(webHits.size ? ' ' + PUBLIC_WEB + ' dans ' + [...webHits].join(', ') : ' aucune');
  console.log('--- Domaines (URL) rencontres, hors schemas XML/doc courants');
  const ignore = /(w3\.org|schemas\.android\.com|apache\.org|xmlpull\.org|android\.com|developer\.android|example\.com|json-schema\.org|ietf\.org)/;
  [...hosts.entries()].filter(([h]) => !ignore.test(h)).sort((a, b) => b[1] - a[1]).slice(0, 40)
    .forEach(([h, n]) => console.log(` ${h} (${n})`));
}

function main(argv) {
  const [dir, googleServices, testMapsKeyFile] = argv;
  if (!dir || !googleServices) {
    console.error('Usage : audit-apk-content.js <dossier> <google-services.json de test> [fichier-cle-maps-de-test]');
    return 2;
  }
  let authorizedKeys;
  try {
    authorizedKeys = loadAuthorizedKeys(googleServices, testMapsKeyFile);
  } catch (error) {
    console.error(error.message);
    return 1;
  }
  const report = auditDirectory(dir, authorizedKeys);
  printReport(report, authorizedKeys);
  return report.bad ? 1 : 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));
module.exports = { loadAuthorizedKeys, labelKey, auditDirectory, main };
