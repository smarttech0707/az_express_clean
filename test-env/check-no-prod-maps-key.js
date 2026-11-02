'use strict';

// Verifie que des artefacts compiles (kernel_blob.bin, contenu extrait de l'APK) ne contiennent pas la cle Google Maps
// de PRODUCTION, ni en UTF-8 ni en UTF-16 (manifeste Android binaire). Les dossiers sont parcourus recursivement.
// Usage : node test-env/check-no-prod-maps-key.js <maps_key.dart de production (sauvegarde)> <fichier-ou-dossier>...
// Code retour 1 si la cle est trouvee. La cle n'est jamais affichee.
const fs = require('fs');
const path = require('path');

const [, , keyFile, ...targets] = process.argv;
if (!keyFile || targets.length === 0) { console.error('Usage : check-no-prod-maps-key.js <maps_key.dart> <fichier-ou-dossier>...'); process.exit(2); }
const m = /AIza[0-9A-Za-z_-]{20,}/.exec(fs.readFileSync(keyFile, 'utf8'));
if (!m) { console.log('Aucune cle de production a rechercher.'); process.exit(0); }
const needles = [Buffer.from(m[0], 'utf8'), Buffer.from(m[0], 'utf16le')];

function* walk(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) for (const e of fs.readdirSync(p)) yield* walk(path.join(p, e));
  else yield p;
}

let bad = 0;
let scanned = 0;
for (const t of targets) {
  if (!fs.existsSync(t)) { console.error(`Absent : ${t}`); bad++; continue; }
  for (const f of walk(t)) {
    scanned++;
    const data = fs.readFileSync(f);
    if (needles.some((n) => data.includes(n))) { console.error(`CLE DE PRODUCTION PRESENTE dans ${f}`); bad++; }
  }
}
if (!bad) console.log(`OK (cle de production absente) : ${scanned} fichier(s) analyse(s)`);
process.exit(bad ? 1 : 0);
