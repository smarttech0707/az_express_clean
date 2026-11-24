'use strict';

// Consentement au partage de données avec les fournisseurs d'IA externes
// (Anthropic, Google Gemini) — exigence App Store 5.1.1(i) / 5.1.2(i).
//
// Source de vérité côté serveur : `ai_consents/{uid}`. Collection non
// déclarée dans firestore.rules → refus par défaut côté client ; seules les
// Cloud Functions (Admin SDK) l'écrivent. `azIaChat` refuse d'appeler un
// modèle sans consentement valide, quelle que soit la version de l'app.
//
// Un changement de `CONSENT_VERSION` (nouvelle donnée ou nouveau fournisseur
// dans le texte montré à l'utilisateur) invalide les consentements existants.

const CONSENT_VERSION = 1;
const CONSENT_PROVIDERS = Object.freeze(['anthropic', 'google']);
const COLLECTION = 'ai_consents';

// Correspondance fournisseur technique (aiRouter) → fournisseur nommé dans le consentement. Un fournisseur absent de
// cette table n'est JAMAIS considéré comme consenti.
const CONSENT_PROVIDER_BY_ROUTER = Object.freeze({ claude: 'anthropic', gemini: 'google' });

// Fournisseurs (noms du routeur) auxquels CE consentement permet de transmettre des données. Lit la liste enregistrée
// dans le document : un consentement sans liste, ou invalide, ne couvre aucun fournisseur. Les consentements déjà
// enregistrés (providers = ['anthropic','google']) restent valides sans migration.
function consentedRouterProviders(consent) {
  if (!isConsentValid(consent) || !Array.isArray(consent.providers)) return [];
  return Object.keys(CONSENT_PROVIDER_BY_ROUTER)
    .filter((router) => consent.providers.includes(CONSENT_PROVIDER_BY_ROUTER[router])
      && CONSENT_PROVIDERS.includes(CONSENT_PROVIDER_BY_ROUTER[router]));
}

async function getConsent(db, uid) {
  const snap = await db.collection(COLLECTION).doc(uid).get();
  return snap.exists ? snap.data() : null;
}

function isConsentValid(consent) {
  return !!consent && consent.granted === true && consent.version === CONSENT_VERSION;
}

async function hasValidConsent(db, uid) {
  return isConsentValid(await getConsent(db, uid));
}

// `version` envoyée par le client = version du texte réellement affiché. Une
// version différente de celle du serveur est refusée : l'utilisateur doit
// mettre l'app à jour pour voir le texte à jour avant d'accepter.
async function setConsent({ db, admin, logAudit, uid, granted, version }) {
  if (granted && version !== CONSENT_VERSION) {
    return { ok: false, reason: 'VERSION_MISMATCH' };
  }
  const now = admin.firestore.FieldValue.serverTimestamp();
  await db.collection(COLLECTION).doc(uid).set(granted
    ? { granted: true, version: CONSENT_VERSION, providers: [...CONSENT_PROVIDERS], grantedAt: now, revokedAt: null, updatedAt: now }
    : { granted: false, version: CONSENT_VERSION, providers: [...CONSENT_PROVIDERS], revokedAt: now, updatedAt: now },
  { merge: true });
  if (typeof logAudit === 'function') {
    await Promise.resolve(logAudit({
      action: granted ? 'ai_consent_granted' : 'ai_consent_revoked',
      userId: uid, userType: 'client', targetId: uid,
      metadata: { version: CONSENT_VERSION, providers: [...CONSENT_PROVIDERS] },
    })).catch(() => {});
  }
  return { ok: true };
}

module.exports = { CONSENT_VERSION, CONSENT_PROVIDERS, CONSENT_PROVIDER_BY_ROUTER, consentedRouterProviders, COLLECTION, getConsent, isConsentValid, hasValidConsent, setConsent };
