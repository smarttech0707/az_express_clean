'use strict';

/**
 * Éligibilité d'une erreur au basculement vers un autre fournisseur IA.
 *
 * POURQUOI : `callWithFallback` ne faisait aucune distinction — toute erreur
 * déclenchait le fournisseur suivant dès que le fallback était activé. Deux
 * conséquences indésirables :
 *   - une clé invalide ou une requête malformée par NOTRE code était réessayée
 *     sur chaque fournisseur, multipliant les appels sortants et masquant la
 *     vraie cause derrière l'erreur du dernier fournisseur ;
 *   - un REFUS DE SÉCURITÉ (`provider_blocked`) était relancé sur un autre
 *     modèle — c'est-à-dire un contournement de garde-fou, jamais acceptable.
 *
 * Principe : on ne bascule que sur une défaillance imputable au fournisseur
 * (indisponibilité, saturation, transport), jamais sur un refus légitime ni
 * sur une erreur dont nous sommes la cause.
 */

// Codes HTTP transitoires, côté fournisseur. 529 est le code « overloaded »
// propre à Anthropic ; 408/504 sont des expirations de passerelle.
const RETRYABLE_HTTP = new Set([408, 425, 429, 500, 502, 503, 504, 529]);

// Codes HTTP imputables à l'appelant : ni la clé, ni la requête, ni les droits
// ne s'amélioreront en changeant de fournisseur.
const CLIENT_HTTP = new Set([400, 401, 402, 403, 404, 405, 409, 410, 413, 422]);

// Codes de transport Node/undici — la requête n'a pas abouti.
const TRANSPORT_CODES = new Set([
  'ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'ECONNABORTED', 'EPIPE',
  'ENOTFOUND', 'EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH', 'UND_ERR_SOCKET',
]);

// Codes applicatifs de nos providers (voir GeminiProvider/BaseProvider).
const RETRYABLE_PROVIDER_CODES = new Set([
  'provider_timeout',        // délai borné dépassé
  'provider_network',        // socket coupée
  'provider_invalid_json',   // réponse illisible du fournisseur
  'provider_empty_response', // aucun texte ni appel d'outil exploitable
  'provider_not_configured', // fournisseur non activé : on passe au suivant
]);

const BLOCKING_PROVIDER_CODES = new Set([
  // Refus de sécurité : relancer sur un autre modèle contournerait la garde.
  'provider_blocked',
  // Mauvaise configuration de NOTRE côté (GEMINI_MODEL absent, etc.).
  'provider_model_not_configured',
]);

// Noms d'erreurs des SDK fournisseurs (Anthropic, OpenAI et compatibles).
const RETRYABLE_ERROR_NAMES = new Set([
  'APIConnectionError', 'APIConnectionTimeoutError', 'InternalServerError',
  'RateLimitError', 'APITimeoutError',
]);
const BLOCKING_ERROR_NAMES = new Set([
  'AuthenticationError', 'PermissionDeniedError', 'BadRequestError',
  'NotFoundError', 'UnprocessableEntityError',
]);

// Erreurs de PROGRAMMATION : une bascule les masquerait derrière l'erreur du
// fournisseur suivant au lieu de les faire remonter.
const PROGRAMMING_ERROR_NAMES = new Set([
  'TypeError', 'ReferenceError', 'SyntaxError', 'RangeError',
]);

/** Extrait un statut HTTP, quelle que soit la forme de l'erreur. */
function httpStatusOf(error) {
  const candidates = [
    error?.httpStatus,
    error?.status,
    error?.statusCode,
    error?.response?.status,
  ];
  for (const value of candidates) {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
  }
  return null;
}

/**
 * @returns {{eligible: boolean, reason: string}}
 *   `eligible` vrai ⇒ tenter le fournisseur suivant.
 *
 * Défaut sur une erreur non reconnue : ÉLIGIBLE. Ce choix tient à une
 * propriété structurelle vérifiée du code appelant — `generateTurn()` retourne
 * AVANT toute exécution d'outil (`azia/index.js`), donc aucune erreur d'outil,
 * de validation métier, de FeexPay ou de Firestore métier ne peut atteindre ce
 * point. La population réelle des erreurs non classées y est donc « panne
 * fournisseur ou transport imprévue », pour laquelle tenter le second
 * fournisseur est exactement le comportement voulu d'un repli.
 *
 * Toutes les classes que le repli ne doit JAMAIS franchir sont, elles,
 * détectées explicitement : authentification, permissions, requête invalide,
 * 4xx, refus de sécurité, mauvaise configuration, erreur de programmation.
 */
function classifyProviderFailure(error) {
  if (!error) return { eligible: false, reason: 'no_error' };

  // 1. Décisions explicites de nos providers — priorité absolue.
  if (error.code && BLOCKING_PROVIDER_CODES.has(error.code)) {
    return { eligible: false, reason: `blocked_code:${error.code}` };
  }
  if (error.name && BLOCKING_ERROR_NAMES.has(error.name)) {
    return { eligible: false, reason: `blocked_name:${error.name}` };
  }
  if (error.name && PROGRAMMING_ERROR_NAMES.has(error.name)) {
    return { eligible: false, reason: `programming_error:${error.name}` };
  }

  // 2. Statut HTTP : un 4xx client n'est jamais rejoué ailleurs.
  const status = httpStatusOf(error);
  if (status !== null) {
    if (CLIENT_HTTP.has(status)) return { eligible: false, reason: `client_http_${status}` };
    if (RETRYABLE_HTTP.has(status)) return { eligible: true, reason: `retryable_http_${status}` };
    if (status >= 400 && status < 500) return { eligible: false, reason: `client_http_${status}` };
    if (status >= 500) return { eligible: true, reason: `retryable_http_${status}` };
  }

  // 3. Codes applicatifs et de transport transitoires.
  if (error.code && RETRYABLE_PROVIDER_CODES.has(error.code)) {
    return { eligible: true, reason: `retryable_code:${error.code}` };
  }
  if (error.code && TRANSPORT_CODES.has(String(error.code).toUpperCase())) {
    return { eligible: true, reason: `transport:${error.code}` };
  }
  if (error.name && RETRYABLE_ERROR_NAMES.has(error.name)) {
    return { eligible: true, reason: `retryable_name:${error.name}` };
  }

  // Panne fournisseur/transport imprévue : tenter le second fournisseur.
  return { eligible: true, reason: 'unclassified_provider_failure' };
}

module.exports = {
  RETRYABLE_HTTP,
  CLIENT_HTTP,
  TRANSPORT_CODES,
  RETRYABLE_PROVIDER_CODES,
  BLOCKING_PROVIDER_CODES,
  PROGRAMMING_ERROR_NAMES,
  httpStatusOf,
  classifyProviderFailure,
};
