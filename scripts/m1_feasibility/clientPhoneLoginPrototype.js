'use strict';
// PROTOTYPE M1 — jetable, non branché sur l'application. Démontre seulement la faisabilité de
// `clientPhoneLogin` (vérification serveur du mot de passe + jeton personnalisé) contre l'ÉMULATEUR Auth.
// Toutes les dépendances sont injectées ; aucun accès au réseau hors 127.0.0.1 n'est possible (garde ci-dessous).

const UNIFORM = Object.freeze({ ok: false, code: 'invalid-credentials', message: 'Identifiants incorrects' });

function assertLocalUrl(url) {
  const host = new URL(url).hostname;
  if (host !== '127.0.0.1' && host !== 'localhost') throw new Error(`M1: refus d'accéder à un hôte non local (${host})`);
}

async function localPost(url, body) {
  assertLocalUrl(url);
  const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

/** Candidats d'e-mail de connexion, dans le même ordre que le client actuel (auth_service.dart:25-43, client_auth_page.dart:160-166). */
function emailCandidates(phone, doc) {
  const cleaned = String(phone).replace(/[^0-9+]/g, ''); // même nettoyage que auth_service.dart:41
  const out = [];
  if (doc && typeof doc.email === 'string' && doc.email && !doc.email.endsWith('@azexpress.app')) out.push(doc.email);
  out.push(`${cleaned}@azexpress.app`);
  out.push(`${phone}@az-seller.ci`);
  return [...new Set(out)];
}

/**
 * deps = { auth (firebase-admin Auth), directory: async phone => docs[], restBase, apiKey, extraClaims?: bool }
 * Retourne soit UNIFORM, soit { ok:true, customToken, role } — jamais d'e-mail.
 */
function makeClientPhoneLogin(deps) {
  const { auth, directory, restBase, apiKey } = deps;
  const signInUrl = `${restBase}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${apiKey}`;
  const dummyPassword = 'x'.repeat(12);

  return async function clientPhoneLogin({ identifier, password }) {
    if (typeof identifier !== 'string' || typeof password !== 'string' || !identifier || !password) return UNIFORM;
    const docs = await directory(identifier);
    // Doublon de numéro : échec uniforme (le client actuel prendrait un document arbitraire, index.js:1721).
    const unique = docs.length === 1 ? docs[0] : null;
    const cleaned = String(identifier).replace(/[^0-9+]/g, '');
    const emails = unique ? emailCandidates(identifier, unique) : [`${cleaned}@azexpress.app`, `${cleaned}@az-seller.ci`, `${cleaned}@unknown.invalid`];
    let verifiedUid = null;
    // Nombre d'appels de vérification FIXE (3) quel que soit le cas, sans sortie anticipée : le temps ne dépend plus de
    // l'existence du compte (à confirmer en conditions réelles : l'émulateur n'est pas représentatif).
    for (let i = 0; i < 3; i++) {
      const email = emails[i] || `${cleaned}@pad${i}.invalid`;
      const r = await localPost(signInUrl, { email, password: unique ? password : dummyPassword, returnSecureToken: true });
      if (unique && !verifiedUid && r.status === 200 && r.body.localId) verifiedUid = r.body.localId;
    }
    if (!verifiedUid) return UNIFORM;
    // Le document de profil doit désigner CE uid (sinon un alias réutilisé ouvrirait un autre compte).
    if (unique.uid !== verifiedUid) return UNIFORM;
    let record;
    try { record = await auth.getUser(verifiedUid); } catch (_) { return UNIFORM; }
    if (record.disabled) return UNIFORM;
    // createCustomToken sur un uid inexistant CRÉERAIT un compte à l'échange : on a vérifié l'existence juste avant.
    const claims = deps.extraClaims ? { ...(record.customClaims || {}) } : undefined;
    const customToken = await auth.createCustomToken(verifiedUid, claims);
    return { ok: true, customToken, role: unique.role };
  };
}

module.exports = { makeClientPhoneLogin, emailCandidates, localPost, assertLocalUrl, UNIFORM };
