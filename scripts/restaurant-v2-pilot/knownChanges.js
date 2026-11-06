'use strict';

// Annexe de changements connus et vérifiés (Mission 7E-55). Le manifeste du lot n'est JAMAIS modifié : cette annexe, stockée hors dépôt,
// déclare les rares changements automatiques déjà constatés et justifiés sur un document du lot.
//
// Trois catégories lors d'un contrôle de conservation ou d'un nettoyage :
//   1. donnée de base attendue (le manifeste) ;
//   2. changement automatique connu et vérifié (cette annexe) ;
//   3. tout le reste = changement inconnu : CONFLIT.
//
// Une entrée ne contient JAMAIS la valeur : seulement le chemin du document, le nom du champ, une empreinte (préfixe SHA-256 de la valeur),
// la date d'observation et une justification. La valeur courante est relue et hachée à chaque contrôle ; si l'empreinte change,
// le jeton a été renouvelé ou remplacé : c'est un conflit, jamais une acceptation automatique.

const crypto = require('node:crypto');

// Liste blanche stricte et exhaustive des exceptions reconnaissables. Toute autre entrée d'annexe est invalide.
const ALLOWED = Object.freeze([Object.freeze({ path: 'clients/t7e-client', field: 'fcmToken' })]);
const ENTRY_KEYS = Object.freeze(['path', 'field', 'fingerprint', 'observedAt', 'justification']);
const MIN_FINGERPRINT = 8;
const MAX_FINGERPRINT = 64;
// Mission 7E-56 : seule une empreinte SHA-256 COMPLÈTE (64 hex) est reconnue. Un préfixe plus court (observation ancienne) reste
// accepté comme trace mais PROVISOIRE : il ne reconnaît aucune exception (le champ redevient un conflit) tant qu'une vérification
// en lecture seule n'a pas calculé l'empreinte complète.
const FULL_FINGERPRINT = 64;

class KnownChangesError extends Error {
  constructor(message) { super(message); this.name = 'KnownChangesError'; this.code = 'INVALID_KNOWN_CHANGES'; }
}

const fingerprintOf = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');

// Valide la structure ; lève KnownChangesError à la moindre irrégularité (annexe invalide = aucune exception reconnue).
function validateAnnex(annex, lotId) {
  const bad = (m) => { throw new KnownChangesError(m); };
  if (!annex || typeof annex !== 'object' || Array.isArray(annex)) bad('annexe absente ou malformée');
  if (annex.version !== 1) bad('version d’annexe inconnue');
  if (annex.lot !== lotId) bad('annexe d’un autre lot');
  if (!Array.isArray(annex.entries)) bad('liste d’entrées absente');
  const seen = new Set();
  for (const e of annex.entries) {
    if (!e || typeof e !== 'object' || Array.isArray(e)) bad('entrée malformée');
    const extra = Object.keys(e).filter((k) => !ENTRY_KEYS.includes(k));
    if (extra.length) bad(`champ inattendu dans l’entrée (${extra.join(',')}) : la valeur ne doit jamais figurer dans l’annexe`);
    for (const k of ENTRY_KEYS) if (typeof e[k] !== 'string' || !e[k].trim()) bad(`entrée sans ${k}`);
    if (!ALLOWED.some((a) => a.path === e.path && a.field === e.field)) bad(`exception non reconnue : ${e.path}:${e.field}`);
    if (!new RegExp(`^[0-9a-f]{${MIN_FINGERPRINT},${MAX_FINGERPRINT}}$`).test(e.fingerprint)) bad('empreinte invalide (hexadécimal minuscule)');
    if (Number.isNaN(Date.parse(e.observedAt))) bad('date d’observation invalide');
    const key = `${e.path}:${e.field}`;
    if (seen.has(key)) bad(`entrée en double : ${key}`);
    seen.add(key);
  }
  return annex;
}

// Classe les champs sensibles d'un document : { known: [...], unexplained: [{field, reason}] }.
// `sensitiveFields` = champs déjà repérés par le contrôle appelant. Sans annexe valide, tout est inexpliqué.
function classifySensitive({ docPath, data, sensitiveFields, annex }) {
  const known = []; const unexplained = [];
  const entries = annex && Array.isArray(annex.entries) ? annex.entries : [];
  for (const field of sensitiveFields) {
    const entry = entries.find((e) => e.path === docPath && e.field === field);
    if (!entry) { unexplained.push({ field, reason: 'champ sensible non déclaré' }); continue; }
    const value = data[field];
    if (typeof value !== 'string' || !value) { unexplained.push({ field, reason: 'valeur de type inattendu' }); continue; }
    if (entry.fingerprint.length !== FULL_FINGERPRINT) { unexplained.push({ field, reason: 'empreinte provisoire (préfixe) : vérification en lecture seule requise pour l’empreinte complète' }); continue; }
    if (fingerprintOf(value) !== entry.fingerprint) { unexplained.push({ field, reason: 'empreinte différente de celle vérifiée (valeur renouvelée ou remplacée)' }); continue; }
    known.push(field);
  }
  return { known, unexplained };
}

// Charge l'annexe depuis un fichier JSON (hors dépôt). Fichier absent = pas d'annexe (aucune exception).
function loadAnnex(fs, file, lotId) {
  if (!file) return null;
  return validateAnnex(JSON.parse(fs.readFileSync(file, 'utf8')), lotId);
}

// Usage autorisé (mission de vérification en lecture seule, plus tard) : la valeur est lue sur l'entrée standard, JAMAIS en argument,
// et seule l'empreinte est affichée :   <source de la valeur> | node knownChanges.js --stdin
if (require.main === module && process.argv[2] === '--stdin') {
  let buf = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { buf += c; });
  process.stdin.on('end', () => {
    const value = buf.replace(/\r?\n$/, '');
    if (!value) { console.error('valeur vide'); process.exit(1); }
    console.log(fingerprintOf(value));
  });
}

module.exports = { FULL_FINGERPRINT,  ALLOWED, KnownChangesError, fingerprintOf, validateAnnex, classifySensitive, loadAnnex };
