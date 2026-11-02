'use strict';

// Audit du contenu d'un APK de test DEJA EXTRAIT dans un dossier : references de production, cles API embarquees, URLs.
// Usage : node test-env/audit-apk-content.js <dossier-extrait> <cle-api-android-de-test-attendue (google-services.json)>
// Les cles ne sont jamais affichees en clair (4 derniers caracteres seulement). Code retour 1 si une reference de production
// ou une cle API inattendue est trouvee.
const fs = require('fs');
const path = require('path');
const g = require('./lib/guards');

const [, , dir, googleServices] = process.argv;
if (!dir || !googleServices) { console.error('Usage : audit-apk-content.js <dossier> <google-services.json de test>'); process.exit(2); }
const testKey = (JSON.parse(fs.readFileSync(googleServices, 'utf8')).client || [])
  .flatMap((c) => (c.api_key || []).map((k) => k.current_key));
// Cle factice de l'emulateur (lib/services/firebase_emulator_config.dart) : non secrete, ne designe aucun projet reel.
const emu = /AIza[0-9A-Za-z_-]{35}/.exec(fs.readFileSync(path.resolve(__dirname, '..', 'lib/services/firebase_emulator_config.dart'), 'utf8'));
if (emu) testKey.push(emu[0]);
// Pages publiques de la production (mentions legales, liens QR) : lien web, aucune donnee. Signale en avertissement.
const PUBLIC_WEB = 'az-express-b0469.web.app';


function* walk(p) {
  for (const e of fs.readdirSync(p, { withFileTypes: true })) {
    const f = path.join(p, e.name);
    if (e.isDirectory()) yield* walk(f); else yield f;
  }
}
const mask = (k) => `AIza…${k.slice(-4)}`;
const keyHits = new Map();
const prodHits = new Map();
const hosts = new Map();
const webHits = new Set();
const urlRe = /https?:\/\/[A-Za-z0-9._-]+(?:\.[A-Za-z]{2,})/g;

for (const f of walk(dir)) {
  const data = fs.readFileSync(f);
  // Les .so/.dex/.arsc/manifeste melangent UTF-8 et UTF-16 : on analyse les deux decodages.
  for (const text of [data.toString('latin1'), data.toString('utf16le')]) {
    for (const k of text.match(/AIza[0-9A-Za-z_-]{35}/g) || []) {
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
console.log('--- Cles API embarquees (masquees)');
for (const [k, files] of keyHits) {
  const known = testKey.includes(k);
  if (!known) bad++;
  console.log(` ${mask(k)} : ${known ? 'cle Firebase de TEST (attendue)' : 'INCONNUE / a examiner'} dans ${[...files].slice(0, 3).join(', ')}`);
}
if (!keyHits.size) console.log(' aucune');
console.log('--- References de production');
for (const [h, files] of prodHits) { bad++; console.log(` « ${h} » dans ${[...files].slice(0, 3).join(', ')}`); }
if (!prodHits.size) console.log(' aucune');
console.log('--- Pages web publiques de production referencees (avertissement, pas une connexion de donnees)');
console.log(webHits.size ? ' ' + PUBLIC_WEB + ' dans ' + [...webHits].join(', ') : ' aucune');
console.log('--- Domaines (URL) rencontres, hors schemas XML/doc courants');
const ignore = /(w3\.org|schemas\.android\.com|apache\.org|xmlpull\.org|android\.com|developer\.android|example\.com|json-schema\.org|ietf\.org)/;
[...hosts.entries()].filter(([h]) => !ignore.test(h)).sort((a, b) => b[1] - a[1]).slice(0, 40)
  .forEach(([h, n]) => console.log(` ${h} (${n})`));
process.exit(bad ? 1 : 0);
