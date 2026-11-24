'use strict';

// Contrôle LOCAL, en lecture seule, à lancer avant `firebase deploy --only hosting` (Mission 7E-64).
//
// Pourquoi : un déploiement Hosting publie TOUT le dossier build/web comme nouvelle version du site (il n'existe pas de
// publication de deux pages seulement). Pour publier /delete-account et /confidentialite sans toucher à la page d'accueil
// ni à l'APK public, on vérifie que le dossier de publication :
//   - contient exactement les pages légales de web/legal ;
//   - garde l'APK et le manifeste de distribution actuellement en ligne (empreinte et taille du manifeste public) ;
//   - n'oublie aucun fichier de la dernière publication (rien ne serait retiré du site) ;
//   - déclare les réécritures des deux routes ;
//   - ne contient aucun fichier secret.
// Aucun accès réseau, aucune écriture. Le manifeste en ligne (web/distribution/latest.json) est celui relevé le 6 novembre 2026.
//
// Usage : node scripts/hosting/verify-legal-release.js [dossierRacine]    (code de sortie 1 si un contrôle échoue)

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const SECRET_NAMES = [/^\.env/, /^key\.properties$/, /\.keystore$/, /\.jks$/, /^google-services\.json$/, /^GoogleService-Info\.plist$/, /service-?account.*\.json$/i];
const REQUIRED_TEXT = {
  'legal/delete-account.html': ['Dans l\'application', 'Supprimer mon compte', 'Depuis ce site', 'Données conservées', 'Durées de conservation'],
  'legal/confidentialite.html': ['7. Conservation', 'Durées de conservation', 'Supprimer mon compte', 'AZ IA'],
};

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

function walk(dir, base = dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const full = path.join(dir, e.name);
    return e.isDirectory() ? walk(full, base) : [path.relative(base, full).split(path.sep).join('/')];
  });
}

function verify(root) {
  const failures = [];
  const ok = [];
  const check = (cond, label) => (cond ? ok : failures).push(label);
  const web = path.join(root, 'web'), build = path.join(root, 'build', 'web');

  check(fs.existsSync(build), 'build/web existe');
  if (!fs.existsSync(build)) return { ok, failures };

  for (const page of Object.keys(REQUIRED_TEXT)) {
    const src = path.join(web, page), out = path.join(build, page);
    const present = fs.existsSync(src) && fs.existsSync(out);
    check(present, `${page} présent dans web/ et build/web/`);
    if (!present) continue;
    check(sha256(src) === sha256(out), `${page} : build/web identique à la source web/`);
    const html = fs.readFileSync(out, 'utf8');
    check(!/<script/i.test(html), `${page} : lisible sans JavaScript (aucun <script>)`);
    check(REQUIRED_TEXT[page].every((t) => html.includes(t)), `${page} : sections obligatoires présentes`);
  }

  // APK et manifeste : ceux de la source sont ceux du manifeste public ; build/web doit contenir exactement les mêmes.
  const manifestPath = path.join(web, 'distribution', 'latest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const apk = path.join(build, 'downloads', 'az-express-latest.apk');
  check(fs.existsSync(apk), 'APK présent dans build/web/downloads');
  if (fs.existsSync(apk)) {
    check(fs.statSync(apk).size === manifest.fileSizeBytes, 'APK : taille = manifeste public');
    check(sha256(apk).toUpperCase() === String(manifest.fileSha256).toUpperCase(), 'APK : SHA-256 = manifeste public');
  }
  const builtManifest = path.join(build, 'distribution', 'latest.json');
  check(fs.existsSync(builtManifest) && sha256(builtManifest) === sha256(manifestPath), 'manifeste de distribution : build/web identique à web/');

  // Aucun fichier de la dernière publication ne doit disparaître.
  const cachePath = path.join(root, '.firebase', 'hosting.YnVpbGRcd2Vi.cache');
  if (fs.existsSync(cachePath)) {
    const published = fs.readFileSync(cachePath, 'utf8').split(/\r?\n/).filter(Boolean).map((l) => l.split(',')[0]);
    const built = new Set(walk(build));
    const missing = published.filter((f) => !built.has(f));
    check(missing.length === 0, `aucun fichier de la dernière publication retiré (${published.length} fichiers)${missing.length ? ' — manquants : ' + missing.slice(0, 5).join(', ') : ''}`);
  } else {
    failures.push('cache de la dernière publication introuvable (.firebase/hosting.*.cache) : impossible de prouver qu\'aucun fichier n\'est retiré');
  }

  // Réécritures de firebase.json.
  const rewrites = (JSON.parse(fs.readFileSync(path.join(root, 'firebase.json'), 'utf8')).hosting || {}).rewrites || [];
  const dest = (src) => (rewrites.find((r) => r.source === src) || {}).destination;
  check(dest('/confidentialite') === '/legal/confidentialite.html', 'réécriture /confidentialite');
  check(dest('/delete-account') === '/legal/delete-account.html', 'réécriture /delete-account');
  const catchAll = rewrites.findIndex((r) => r.source === '**');
  check(catchAll === rewrites.length - 1, 'la règle « ** » reste la dernière réécriture');

  const secrets = walk(build).filter((f) => SECRET_NAMES.some((re) => re.test(path.basename(f))));
  check(secrets.length === 0, `aucun fichier secret dans build/web${secrets.length ? ' : ' + secrets.join(', ') : ''}`);

  return { ok, failures };
}

if (require.main === module) {
  const { ok, failures } = verify(path.resolve(process.argv[2] || path.join(__dirname, '..', '..')));
  for (const l of ok) console.log('OK    ' + l);
  for (const l of failures) console.log('ÉCHEC ' + l);
  console.log(failures.length ? `\n${failures.length} contrôle(s) en échec : NE PAS déployer.` : '\nTous les contrôles passent.');
  process.exit(failures.length ? 1 : 0);
}

module.exports = { verify };
