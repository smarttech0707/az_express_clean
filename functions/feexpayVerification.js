'use strict';

/**
 * Vérification officielle du statut d'un PAYOUT FeexPay V2.
 *
 *   GET https://api-v2.feexpay.me/api/payouts/status/public/{reference}
 *   Authorization: Bearer <clé serveur>
 *
 * La documentation FeexPay impose cette vérification : une initiation qui
 * répond `status: "PENDING"` / "Payout request accepted" ne prouve PAS que
 * l'argent est arrivé chez le bénéficiaire. Seuls SUCCESSFUL et FAILED sont
 * des états finaux ; PENDING et "IN PENDING STATE" signifient « en cours ».
 *
 * Règles de sûreté appliquées ici :
 *   - une erreur réseau, un 5xx ou un JSON illisible ne deviennent JAMAIS
 *     un FAILED (cela déclencherait un remboursement alors que le transfert
 *     a pu aboutir) : ils sont classés `network_error` / `unknown` ;
 *   - aucun jeton, aucune URL complète n'est journalisé ou renvoyé ;
 *   - la référence est validée strictement puis encodée avant l'appel.
 *
 * ⚠️ Périmètre : PAYOUT uniquement. Aucun endpoint de vérification de
 * COLLECTE n'est documenté à ce jour — voir `createStatusVerifier`.
 */

const PAYOUT_STATUS_PATH = '/api/payouts/status/public';
const PAYOUT_API_BASE = 'https://api-v2.feexpay.me';

// Statuts documentés par FeexPay. Rien d'autre n'est interprété.
const PAYOUT_FINAL_SUCCESS = 'SUCCESSFUL';
const PAYOUT_FINAL_FAILURE = 'FAILED';
const PAYOUT_PENDING_STATUSES = ['PENDING', 'IN PENDING STATE'];

// Une référence FeexPay est un identifiant opaque : on refuse tout ce qui
// pourrait altérer le chemin de l'URL ou dépasser une taille raisonnable.
const REFERENCE_PATTERN = /^[A-Za-z0-9._:-]{6,128}$/;

function isValidReference(reference) {
  return typeof reference === 'string' && REFERENCE_PATTERN.test(reference.trim());
}

/**
 * Normalise le statut renvoyé par FeexPay.
 * @returns {'successful'|'failed'|'pending'|'unknown'}
 */
function normalizePayoutStatus(rawStatus) {
  const value = String(rawStatus || '').trim().toUpperCase();
  if (value === PAYOUT_FINAL_SUCCESS) return 'successful';
  if (value === PAYOUT_FINAL_FAILURE) return 'failed';
  if (PAYOUT_PENDING_STATUSES.includes(value)) return 'pending';
  return 'unknown';
}

/**
 * Vérificateur de statut Payout. `token` est une fonction (lecture paresseuse
 * du secret) : la valeur n'est jamais stockée ni journalisée ici.
 */
function createPayoutStatusVerifier({ axios, apiUrl = PAYOUT_API_BASE, token, timeoutMs = 20000 } = {}) {
  if (!axios || !token) return null;

  return {
    /**
     * @returns {{outcome:'successful'|'failed'|'pending'|'unknown'|'network_error'|'invalid_reference',
     *            reference?:string, amount?:number|null, providerStatus?:string, meta?:object,
     *            reason?:string}}
     */
    async checkPayoutStatus(reference) {
      if (!isValidReference(reference)) {
        return { outcome: 'invalid_reference', reason: 'reference_malformed' };
      }
      const clean = reference.trim();

      let response;
      try {
        response = await axios.get(
          `${apiUrl}${PAYOUT_STATUS_PATH}/${encodeURIComponent(clean)}`,
          {
            headers: { Authorization: `Bearer ${token()}` },
            timeout: timeoutMs,
          },
        );
      } catch (err) {
        // Jamais de FAILED sur une erreur de transport : le transfert a pu
        // aboutir. On ne remonte ni l'URL ni l'en-tête d'autorisation.
        const httpStatus = err?.response?.status ?? null;
        return {
          outcome: 'network_error',
          reason: httpStatus ? `http_${httpStatus}` : 'no_response',
        };
      }

      // Parsing défensif : une réponse non-objet est inexploitable, pas un échec.
      const data = response?.data;
      if (!data || typeof data !== 'object' || Array.isArray(data)) {
        return { outcome: 'unknown', reason: 'unparsable_payload' };
      }

      const outcome = normalizePayoutStatus(data.status);
      const amountRaw = data.amount;
      const amount = typeof amountRaw === 'number' && Number.isFinite(amountRaw)
        ? amountRaw
        : (typeof amountRaw === 'string' && /^\d+(\.\d+)?$/.test(amountRaw.trim())
          ? Number(amountRaw.trim())
          : null);

      return {
        outcome,
        reference: typeof data.reference === 'string' ? data.reference.trim() : null,
        amount,
        providerStatus: String(data.status || '').trim().toUpperCase() || null,
        // Métadonnées documentées, toutes non sensibles.
        meta: {
          responsecode: data.responsecode ?? null,
          responsemsg: data.responsemsg ?? null,
          transref: data.transref ?? null,
          serviceref: data.serviceref ?? null,
          reason: data.reason ?? null,
          description: data.description ?? null,
          providerDate: data.date ?? null,
        },
      };
    },
  };
}

// Endpoint officiel de vérification d'une transaction de COLLECTE, confirmé
// par FeexPay. C'est la SEULE source de vérité financière d'un encaissement :
// le webhook n'est qu'une notification.
const TRANSACTION_STATUS_PATH = '/api/transactions/public/single/status';
const TRANSACTION_API_BASE = 'https://api-v2.feexpay.me';

/**
 * Normalise un montant de façon défensive. Aucune valeur ambiguë n'est
 * acceptée silencieusement : seuls un nombre fini ou une chaîne strictement
 * numérique sont convertis, tout le reste retourne `null` (donc un refus).
 */
function normalizeAmount(value) {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? Math.round(value) : null;
  }
  if (typeof value === 'string') {
    const cleaned = value.replace(/\s/g, '').replace(',', '.');
    if (!/^\d+(\.\d+)?$/.test(cleaned)) return null;
    const parsed = Number(cleaned);
    return Number.isFinite(parsed) ? Math.round(parsed) : null;
  }
  return null;  // booléen, objet, tableau, null, undefined → jamais accepté
}

/**
 * Vérification serveur d'un encaissement.
 *
 *   GET https://api-v2.feexpay.me/api/transactions/public/single/status/{reference}
 *   Authorization: Bearer <clé serveur>
 *
 * Décision financière fondée UNIQUEMENT sur les trois champs officiellement
 * confirmés : `reference`, `amount`, `status`. Les autres champs de la réponse
 * (phoneNumber, transref, responsecode, date…) peuvent exister mais ne sont
 * jamais des préconditions. Aucune devise n'est exigée : FeexPay a confirmé
 * qu'aucun champ devise n'est fourni.
 *
 * FAIL CLOSED : toute situation autre qu'un SUCCESSFUL dont la référence ET
 * le montant correspondent retourne `confirmed:false` — y compris une erreur
 * réseau, un 5xx, un JSON illisible ou un statut PENDING.
 */
function createStatusVerifier({
  axios, apiUrl = TRANSACTION_API_BASE, token, timeoutMs = 20000,
} = {}) {
  if (!axios || !token) return null;

  return {
    async confirmPayment({ txId, expectedAmount }) {
      if (!isValidReference(txId)) {
        return { confirmed: false, reason: 'reference_malformed' };
      }
      const clean = String(txId).trim();

      let response;
      try {
        response = await axios.get(
          `${apiUrl}${TRANSACTION_STATUS_PATH}/${encodeURIComponent(clean)}`,
          { headers: { Authorization: `Bearer ${token()}` }, timeout: timeoutMs },
        );
      } catch (err) {
        // Une vérification impossible n'est jamais une confirmation.
        // Ni l'URL ni l'en-tête d'autorisation ne sont remontés.
        const httpStatus = err?.response?.status ?? null;
        return {
          confirmed: false,
          reason: httpStatus ? `verification_http_${httpStatus}` : 'verification_unavailable',
        };
      }

      const data = response?.data;
      if (!data || typeof data !== 'object' || Array.isArray(data)) {
        return { confirmed: false, reason: 'unparsable_payload' };
      }

      const status = String(data.status || '').trim().toUpperCase();
      if (status !== 'SUCCESSFUL') {
        // PENDING, FAILED, vide ou inconnu : aucun crédit.
        return { confirmed: false, reason: `status:${status || 'absent'}` };
      }

      const returnedReference = typeof data.reference === 'string' ? data.reference.trim() : '';
      if (!returnedReference || returnedReference !== clean) {
        return { confirmed: false, reason: 'reference_mismatch' };
      }

      const amount = normalizeAmount(data.amount);
      const expected = normalizeAmount(expectedAmount);
      if (amount === null || expected === null) {
        return { confirmed: false, reason: 'amount_unreadable' };
      }
      if (amount !== expected) {
        return { confirmed: false, reason: 'amount_mismatch', amount };
      }

      return { confirmed: true, amount, reference: returnedReference };
    },
  };
}

/** Doublure de test uniquement — jamais utilisée par `index.js`. */
function createFakeVerifier(responder) {
  return { confirmPayment: async (args) => responder(args) };
}

/** Doublure de test pour le vérificateur de payout. */
function createFakePayoutVerifier(responder) {
  return { checkPayoutStatus: async (reference) => responder(reference) };
}

module.exports = {
  PAYOUT_API_BASE,
  PAYOUT_STATUS_PATH,
  PAYOUT_PENDING_STATUSES,
  TRANSACTION_API_BASE,
  TRANSACTION_STATUS_PATH,
  isValidReference,
  normalizeAmount,
  normalizePayoutStatus,
  createPayoutStatusVerifier,
  createStatusVerifier,
  createFakeVerifier,
  createFakePayoutVerifier,
};
