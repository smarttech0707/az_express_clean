'use strict';

// Verifie que des artefacts compiles (kernel_blob.bin, contenu extrait de l'APK) ne contiennent pas la cle Google Maps
// de PRODUCTION, ni en UTF-8 ni en UTF-16 (manifeste Android binaire). Les dossiers sont parcourus recursivement.
// Usage : node test-env/check-no-prod-maps-key.js <maps_key.dart de production (sauvegarde)> <fichier-ou-dossier>...
// Code retour 1 si la cle est trouvee. La cle n'est jamais affichee.
//
// ECHEC FERME (M2.9) : si la cle de production ne peut pas etre identifiee de facon fiable dans le fichier de
// reference (aucune cle, plusieurs cles differentes, forme inattendue) ou si rien n'a ete analyse, le controle
// REFUSE (code 1) au lieu de conclure que le build est sur.
const fs = require('fs');
const path = require('path');

// Forme d'une cle d'API Google : "AIza" suivi de 35 caracteres.
const STRICT = /AIza[0-9A-Za-z_-]{35}/g;
const LOOSE = /AIza[0-9A-Za-z_-]{20,}/g;

// Renvoie { key } si exactement une cle de forme valide est presente, sinon { error } (jamais la cle).
function identifyKey(text) {
  const strict = new Set(text.match(STRICT) || []);
  const loose = new Set(text.match(LOOSE) || []);
  if (loose.size === 0) return { error: 'aucune cle Google Maps de production identifiable dans le fichier de reference' };
  if (strict.size === 0 || loose.size !== 1 || strict.size !== 1) {
    return { error: 'cle de production ambigue ou de forme inattendue dans le fichier de reference' };
  }
  const key = [...strict][0];
  if ([...loose][0].length !== key.length) return { error: 'cle de production de longueur inattendue dans le fichier de reference' };
  return { key };
}

function* walk(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) for (const e of fs.readdirSync(p)) yield* walk(path.join(p, e));
  else yield p;
}

function main(argv) {
  const [keyFile, ...targets] = argv;
  if (!keyFile || targets.length === 0) {
    console.error('Usage : check-no-prod-maps-key.js <maps_key.dart> <fichier-ou-dossier>...');
    return 2;
  }
  let reference;
  try { reference = fs.readFileSync(keyFile, 'utf8'); } catch (_) {
    console.error('REFUS : fichier de reference illisible.');
    return 1;
  }
  const identified = identifyKey(reference);
  if (identified.error) {
    console.error(`REFUS : ${identified.error}.`);
    return 1;
  }
  const needles = [Buffer.from(identified.key, 'utf8'), Buffer.from(identified.key, 'utf16le')];
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
  if (scanned === 0) {
    console.error('REFUS : aucun fichier analyse.');
    return 1;
  }
  if (!bad) console.log(`OK (cle de production absente) : ${scanned} fichier(s) analyse(s)`);
  return bad ? 1 : 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));
module.exports = { identifyKey, main };
