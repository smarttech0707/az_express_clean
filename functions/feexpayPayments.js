'use strict';

/**
 * Décisions de paiement FeexPay, isolées de `index.js` pour être testables
 * hors ligne (aucun import Firebase, aucun appel réseau ici).
 *
 * ⚠️ LIMITE DOCUMENTAIRE — À LIRE AVANT TOUTE ACTIVATION PRODUCTION
 * Le dépôt ne contient AUCUNE documentation officielle FeexPay : ni liste
 * exhaustive des statuts, ni nom du champ portant le montant réellement
 * encaissé, ni endpoint de vérification de statut, ni schéma de signature.
 * Rien n'est donc inventé ici :
 *   - les listes de statuts reprennent exactement celles déjà en production ;
 *   - les noms de champs candidats pour le montant sont explicitement marqués
 *     NON CONFIRMÉS et un champ absent n'est JAMAIS considéré comme valide ;
 *   - la vérification indépendante du paiement vit derrière une interface
 *     (`feexpayVerification.js`) qui reste non configurée tant que l'endpoint
 *     officiel n'est pas connu.
 */

// Statuts déjà traités en production (functions/index.js, avant extraction).
const PAYMENT_SUCCESS_STATUSES = ['SUCCESSFUL', 'SUCCESS', 'COMPLETED', 'PAID'];
const PAYMENT_FAILURE_STATUSES = ['FAILED', 'CANCELLED', 'CANCELED', 'REJECTED'];

// ⚠️ NOMS NON CONFIRMÉS PAR FEEXPAY. Utilisés uniquement pour détecter un
// montant s'il est présent ; leur absence ne vaut jamais validation.
const PAID_AMOUNT_FIELD_CANDIDATES = ['amount', 'montant', 'amount_paid', 'paid_amount'];
const CURRENCY_FIELD_CANDIDATES = ['currency', 'devise'];
const EXPECTED_CURRENCY = 'XOF';

// Reste à false tant que FeexPay n'a pas confirmé le nom du champ de montant.
// À true, un webhook sans montant exploitable ne crédite plus rien.
const STRICT_AMOUNT_VERIFICATION = false;

const DEFAULT_MAX_AGE_MS = 24 * 60 * 60 * 1000;

function classifyPaymentStatus(rawStatus) {
  const normalized = String(rawStatus || '').trim().toUpperCase();
  if (PAYMENT_SUCCESS_STATUSES.includes(normalized)) return { kind: 'success', normalized };
  if (PAYMENT_FAILURE_STATUSES.includes(normalized)) return { kind: 'failure', normalized };
  return { kind: 'unknown', normalized };
}

// Le txId est l'identifiant que NOUS avons fourni à FeexPay (`id`), renvoyé
// selon les cas dans order_id / id / custom_id / reference.
function extractTransactionId(body) {
  const raw = body?.order_id || body?.id || body?.custom_id || body?.reference;
  const value = typeof raw === 'string' || typeof raw === 'number' ? String(raw).trim() : '';
  // Un txId est un identifiant de document Firestore : jamais un chemin.
  if (!value || value.includes('/') || value.length > 200) return null;
  return value;
}

function isAuthorizedWebhookCall({ method, receivedSecret, expectedSecret }) {
  if (method !== 'POST') return { ok: false, httpStatus: 405, reason: 'method_not_allowed' };
  if (!expectedSecret) return { ok: false, httpStatus: 503, reason: 'secret_not_configured' };
  if (!receivedSecret || receivedSecret !== expectedSecret) {
    return { ok: false, httpStatus: 401, reason: 'invalid_secret' };
  }
  return { ok: true };
}

function toInteger(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.round(value);
  if (typeof value === 'string') {
    // Tolère "1 500", "1500.00", "1500,00" sans jamais deviner une devise.
    const cleaned = value.replace(/\s/g, '').replace(',', '.');
    if (!/^-?\d+(\.\d+)?$/.test(cleaned)) return null;
    return Math.round(Number(cleaned));
  }
  return null;
}

function extractPaidAmount(body) {
  for (const field of PAID_AMOUNT_FIELD_CANDIDATES) {
    if (body && Object.prototype.hasOwnProperty.call(body, field)) {
      const amount = toInteger(body[field]);
      if (amount !== null) return { found: true, amount, field };
      return { found: true, amount: null, field };  // présent mais illisible
    }
  }
  return { found: false, amount: null, field: null };
}

function extractCurrency(body) {
  for (const field of CURRENCY_FIELD_CANDIDATES) {
    if (body && Object.prototype.hasOwnProperty.call(body, field)) {
      return String(body[field] || '').trim().toUpperCase() || null;
    }
  }
  return null;
}

/**
 * Compare le montant encaissé au montant attendu.
 * - montant présent et identique  -> ok, vérifié
 * - montant présent et différent  -> REFUS (quel que soit le mode)
 * - devise présente et différente -> REFUS
 * - montant absent                -> jamais "valide" : `verified:false`.
 *   En mode strict, refus ; sinon accepté mais explicitement non vérifié,
 *   pour ne pas casser un encaissement réel sur une simple hypothèse de nom
 *   de champ (voir LIMITE DOCUMENTAIRE en tête de fichier).
 */
function verifyPaidAmount({ expectedAmount, body, strict = STRICT_AMOUNT_VERIFICATION }) {
  const paid = extractPaidAmount(body);
  const currency = extractCurrency(body);

  if (currency && currency !== EXPECTED_CURRENCY) {
    return { ok: false, verified: false, reason: 'currency_mismatch', paidAmount: paid.amount, currency };
  }
  if (!paid.found) {
    return strict
      ? { ok: false, verified: false, reason: 'amount_absent', paidAmount: null, currency }
      : { ok: true, verified: false, reason: 'amount_absent_unverified', paidAmount: null, currency };
  }
  if (paid.amount === null) {
    return { ok: false, verified: false, reason: 'amount_unreadable', paidAmount: null, currency };
  }
  if (toInteger(expectedAmount) !== paid.amount) {
    return { ok: false, verified: false, reason: 'amount_mismatch', paidAmount: paid.amount, currency };
  }
  return { ok: true, verified: true, reason: 'amount_match', paidAmount: paid.amount, currency };
}

// ── DIAGNOSTIC DES ÉCHECS D'INITIATION DE COLLECTE ──────────────────────────
// Un test réel a échoué sur un HTTP 502 : l'ancien `catch` ne retenait que
// `err.response?.data?.message || err.message`. Un 502 provenant d'une
// passerelle n'a pas de `data.message` → le message remonté était celui
// du client HTTP (« Request failed with status code 502 »), affiché tel quel dans
// l'application, et AUCUN journal structuré n'était écrit côté serveur.
// Ce bloc ne change aucune décision financière : il ne fait qu'extraire des
// champs sûrs et qualifier l'ambiguïté de l'échec.

// L'expurgation vit dans son propre module : voir l'en-tête de
// `feexpaySanitize.js` pour la raison (garde-fou structurel de ce fichier).
const { sanitizeProviderMessage } = require('./feexpaySanitize');

// Un retrait ambigu ne doit pas pouvoir être relancé aveuglément : FeexPay a
// peut-être créé la transaction et envoyé une demande au téléphone. On bloque
// une nouvelle tentative pendant cette fenêtre, sans jamais la bloquer
// indéfiniment (sinon un utilisateur resterait coincé si aucun webhook
// n'arrive jamais).
const UNCERTAIN_RETRY_BLOCK_MS = 30 * 60 * 1000;
const COLLECT_UNCERTAIN_STATUS = 'provider_uncertain';

/**
 * Extrait d'une erreur du client HTTP les SEULS champs sûrs pour le diagnostic.
 * Un corps non-objet (HTML de passerelle, texte brut) ne produit AUCUN
 * message : on ne journalise jamais un corps brut.
 */
function extractProviderError(error) {
  const out = {
    httpStatus: null,
    providerCode: null,
    providerStatus: null,
    providerMessage: null,
    providerReference: null,
    bodyKind: 'none',
    transportCode: null,
  };
  if (!error) return out;

  out.httpStatus = error.response?.status ?? null;
  const transport = typeof error.code === 'string' ? error.code : null;
  // Codes de transport du client HTTP / Node : énumératifs, aucun contenu arbitraire.
  out.transportCode = transport ? transport.replace(/[^A-Z0-9_]/gi, '').slice(0, 32) || null : null;

  const data = error.response?.data;
  if (typeof data === 'string') {
    out.bodyKind = 'text';           // jamais exploité, jamais journalisé
    return out;
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    if (!out.httpStatus) out.bodyKind = 'none';
    return out;
  }
  out.bodyKind = 'json';

  const enumOnly = (value) => (typeof value === 'string' || typeof value === 'number'
    ? String(value).replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 64) || null
    : null);

  out.providerCode = enumOnly(data.code ?? data.errorCode ?? data.responsecode);
  out.providerStatus = enumOnly(data.status ?? data.state);
  out.providerReference = enumOnly(data.reference ?? data.transref ?? data.request_id);

  const rawMessage = data.message ?? data.error ?? data.responsemsg ?? data.description;
  if (typeof rawMessage === 'string' && rawMessage.trim()) {
    out.providerMessage = sanitizeProviderMessage(rawMessage);
  }
  return out;
}

/**
 * Qualifie un échec d'initiation de COLLECTE.
 *
 * Principe identique à `classifyPayoutInitiation` : un code HTTP ne suffit
 * pas à conclure que rien n'a été créé. Une 5xx, un timeout ou une absence de
 * réponse laissent l'état INCERTAIN — FeexPay a pu enregistrer la demande et
 * solliciter le téléphone du client. Seule une erreur 4xx sans référence
 * permet de conclure qu'aucune transaction n'existe côté fournisseur.
 *
 * @returns {{ambiguous:boolean, txStatus:string, reason:string, ...safeFields}}
 */
function classifyCollectInitiationFailure(error) {
  const safe = extractProviderError(error);
  const status = safe.httpStatus;

  // Référence fournisseur présente malgré l'erreur : la transaction existe
  // probablement → jamais un échec définitif.
  if (safe.providerReference) {
    return { ...safe, ambiguous: true, txStatus: COLLECT_UNCERTAIN_STATUS, reason: 'error_with_reference' };
  }
  if (status === null) {
    // Aucune réponse : timeout, DNS, socket coupé. La requête a pu partir.
    return {
      ...safe,
      ambiguous: true,
      txStatus: COLLECT_UNCERTAIN_STATUS,
      reason: safe.transportCode === 'ECONNABORTED' || safe.transportCode === 'ETIMEDOUT'
        ? 'timeout'
        : 'no_response',
    };
  }
  if (status >= 500 || status === 408) {
    // 502/503/504 : une passerelle a échoué, pas forcément FeexPay lui-même.
    return { ...safe, ambiguous: true, txStatus: COLLECT_UNCERTAIN_STATUS, reason: `http_${status}` };
  }
  if (status >= 400) {
    // Refus explicite avant création : conclure est sûr.
    return { ...safe, ambiguous: false, txStatus: 'error', reason: 'provider_rejected' };
  }
  return { ...safe, ambiguous: true, txStatus: COLLECT_UNCERTAIN_STATUS, reason: `http_${status}` };
}

/**
 * Construit la ligne de journal structurée. Ne contient ni jeton, ni URL
 * complète, ni téléphone, ni corps brut — uniquement des champs qualifiés.
 */
function buildInitiationFailureLog(verdict, txId) {
  return [
    'event=feexpay_initiation_failed',
    'provider=FeexPay',
    `txId=${txId}`,
    `httpStatus=${verdict.httpStatus ?? 'null'}`,
    `transportCode=${verdict.transportCode ?? 'null'}`,
    `providerCode=${verdict.providerCode ?? 'null'}`,
    `providerStatus=${verdict.providerStatus ?? 'null'}`,
    `providerReference=${verdict.providerReference ?? 'null'}`,
    `bodyKind=${verdict.bodyKind}`,
    `ambiguous=${verdict.ambiguous}`,
    `reason=${verdict.reason}`,
    `providerMessage=${verdict.providerMessage ?? 'null'}`,
  ].join(' ');
}

// ── PAYOUT V2 ───────────────────────────────────────────────────────────────
// Endpoints documentés par FeexPay pour la Côte d'Ivoire. Allowlist stricte :
// un opérateur inconnu n'est jamais rattaché à un endpoint par défaut (le
// mapping historique de la COLLECTE, lui, retombe sur MTN — comportement
// conservé pour ne pas toucher à l'encaissement, hors périmètre ici).
const PAYOUT_ENDPOINTS = Object.freeze({
  mtn: 'mtn_ci',
  orange: 'orange_ci',
  moov: 'moov_ci',
  wave: 'wave_ci',
});
const PAYOUT_API_BASE = 'https://api-v2.feexpay.me';
const PAYOUT_PATH = '/api/payouts/public';
const PAYOUT_MIN_AMOUNT = 100;
const PAYOUT_MOTIF_MAX_LENGTH = 30;

function resolvePayoutEndpoint(operator, apiBase = PAYOUT_API_BASE) {
  const slug = PAYOUT_ENDPOINTS[String(operator || '').trim().toLowerCase()];
  if (!slug) return { ok: false, reason: 'unknown_operator' };
  return { ok: true, slug, url: `${apiBase}${PAYOUT_PATH}/${slug}` };
}

// Motif documenté : obligatoire, 30 caractères maximum, sans caractère
// spécial. On normalise plutôt que de laisser FeexPay rejeter la demande.
function sanitizePayoutMotif(raw, fallback = 'Retrait AZ Express') {
  const base = String(raw || fallback);
  const cleaned = base.normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^A-Za-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
  const safe = (cleaned || 'Retrait AZ Express').slice(0, PAYOUT_MOTIF_MAX_LENGTH).trim();
  return safe;
}

/**
 * Préconditions à vérifier AVANT tout débit du wallet : un débit suivi d'une
 * initiation impossible laisserait l'argent bloqué dans un état ambigu.
 * `shopId` est une valeur de configuration serveur (jamais codée en dur,
 * jamais journalisée) : seule sa présence est contrôlée ici.
 */
function assertWithdrawalCanStart({ operator, shopId }) {
  const endpoint = resolvePayoutEndpoint(operator);
  if (!endpoint.ok) {
    return { ok: false, code: 'invalid-argument', reason: 'unknown_operator' };
  }
  if (!String(shopId || '').trim()) {
    return { ok: false, code: 'failed-precondition', reason: 'shop_id_missing' };
  }
  return { ok: true, endpoint };
}

/**
 * Classe la réponse d'INITIATION d'un payout.
 *
 * Principe financier conservateur (révision de la logique précédente) : un
 * code HTTP ne suffit plus à conclure un échec. Dès qu'une référence FeexPay
 * existe — ou que le résultat distant est incertain — l'état reste ambigu et
 * aucun remboursement n'est déclenché. Seule une réponse d'erreur SANS aucune
 * référence permet de conclure que rien n'a été créé.
 */
function classifyPayoutInitiation({ response, error }) {
  const readReference = (payload) => {
    const ref = payload?.reference;
    return typeof ref === 'string' && ref.trim() ? ref.trim() : null;
  };

  if (error) {
    const httpStatus = error.response?.status ?? null;
    const reference = readReference(error.response?.data);
    if (reference) {
      // Une référence existe malgré l'erreur : le payout a pu être créé.
      return { outcome: 'ambiguous', reason: 'error_with_reference', reference, httpStatus };
    }
    if (httpStatus && httpStatus >= 400 && httpStatus < 500) {
      return { outcome: 'rejected_no_reference', reason: 'provider_rejected', httpStatus };
    }
    return { outcome: 'ambiguous', reason: httpStatus ? `http_${httpStatus}` : 'no_response', httpStatus };
  }

  const data = response?.data;
  const reference = readReference(data);
  const providerStatus = String(data?.status || '').trim().toUpperCase() || null;
  if (!reference) {
    // Accepté sans référence : impossible de vérifier plus tard → ambigu.
    return { outcome: 'ambiguous', reason: 'accepted_without_reference', providerStatus };
  }
  return { outcome: 'accepted', reason: 'payout_requested', reference, providerStatus };
}

/**
 * Applique un résultat de vérification de statut sur une demande de retrait.
 * Tout est fait dans une seule transaction Firestore : lecture d'état,
 * décision, mutation financière. Garanties :
 *   - SUCCESSFUL finalise exactement une fois, sans jamais recréditer ;
 *   - FAILED compense exactement une fois ;
 *   - PENDING / réseau / inconnu ne déplacent jamais d'argent ;
 *   - une contradiction (FAILED après SUCCESSFUL, ou l'inverse) est détectée
 *     et tracée, sans mouvement financier silencieux ;
 *   - un écart de montant ou de référence bascule en revue, sans mouvement.
 */
async function applyPayoutStatus({
  db, admin, withdrawId, verdict, collectionFor,
  logAudit = async () => {}, logSecurityEvent = async () => {},
}) {
  const wdRef = db.collection('withdrawal_requests').doc(withdrawId);
  const anomalies = [];

  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(wdRef);
    if (!snap.exists) return { applied: false, state: 'not_found' };
    const wd = snap.data();

    const stamp = admin.firestore.FieldValue.serverTimestamp();
    const baseUpdate = { lastStatusCheckAt: stamp };

    // ── États déjà finaux : détection de contradiction, jamais de mouvement ──
    const alreadySuccessful = wd.settlementConfirmed === true;
    const alreadyCompensated = wd.compensated === true;

    if (verdict.outcome === 'successful' && alreadyCompensated) {
      anomalies.push(['payout_success_after_refund', 'high']);
      tx.update(wdRef, { ...baseUpdate, anomaly: 'success_after_refund', needsReview: true });
      return { applied: false, state: 'inconsistent_success_after_refund' };
    }
    if (verdict.outcome === 'failed' && alreadySuccessful) {
      anomalies.push(['payout_failed_after_success', 'high']);
      tx.update(wdRef, { ...baseUpdate, anomaly: 'failed_after_success', needsReview: true });
      return { applied: false, state: 'inconsistent_failed_after_success' };
    }
    if (alreadySuccessful && verdict.outcome === 'successful') {
      tx.update(wdRef, baseUpdate);
      return { applied: false, state: 'already_successful' };
    }
    if (alreadyCompensated && verdict.outcome === 'failed') {
      tx.update(wdRef, baseUpdate);
      return { applied: false, state: 'already_compensated' };
    }

    // ── Cohérence référence / montant avant toute finalisation ──────────────
    if (['successful', 'failed'].includes(verdict.outcome)) {
      if (verdict.reference && wd.providerReference && verdict.reference !== wd.providerReference) {
        anomalies.push(['payout_reference_mismatch', 'high']);
        tx.update(wdRef, {
          ...baseUpdate, status: 'pending_manual', needsReview: true,
          anomaly: 'reference_mismatch', autoRetryBlocked: true,
        });
        return { applied: false, state: 'reference_mismatch' };
      }
      if (verdict.amount != null && Math.round(verdict.amount) !== Math.round(wd.amount)) {
        anomalies.push(['payout_amount_mismatch', 'high']);
        tx.update(wdRef, {
          ...baseUpdate, status: 'pending_manual', needsReview: true,
          anomaly: 'amount_mismatch', autoRetryBlocked: true,
        });
        return { applied: false, state: 'amount_mismatch' };
      }
    }

    // ── SUCCESSFUL : finalisation, aucun mouvement de solde ─────────────────
    if (verdict.outcome === 'successful') {
      tx.update(wdRef, {
        ...baseUpdate,
        status: 'sent',
        providerStatus: verdict.providerStatus || 'SUCCESSFUL',
        settlementConfirmed: true,
        settledAt: stamp,
        autoRetryBlocked: true,
        needsReview: false,
        ...(verdict.meta ? { providerMeta: verdict.meta } : {}),
      });
      return { applied: true, state: 'settled', userId: wd.userId, userType: wd.userType, amount: wd.amount };
    }

    // ── FAILED : compensation unique et atomique ────────────────────────────
    if (verdict.outcome === 'failed') {
      const colName = collectionFor(wd.userType);
      const userRef = db.collection(colName).doc(wd.userId);
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) {
        tx.update(wdRef, { ...baseUpdate, needsReview: true, anomaly: 'user_not_found' });
        return { applied: false, state: 'user_not_found' };
      }
      const wallet = userSnap.data().wallet || 0;
      tx.update(userRef, { wallet: wallet + wd.amount });
      tx.update(wdRef, {
        ...baseUpdate,
        status: 'failed_refunded',
        providerStatus: verdict.providerStatus || 'FAILED',
        settlementConfirmed: false,
        compensated: true,
        compensatedAt: stamp,
        autoRetryBlocked: true,
        ...(verdict.meta ? { providerMeta: verdict.meta } : {}),
      });
      const histRef = db.collection(colName).doc(wd.userId)
        .collection('wallet_transactions').doc();
      tx.set(histRef, {
        type: 'refund',
        amount: wd.amount,
        description: `Remboursement retrait échoué — ${wd.amount} FCFA`,
        withdrawId,
        createdAt: stamp,
      });
      return { applied: true, state: 'compensated', userId: wd.userId, userType: wd.userType, amount: wd.amount };
    }

    // ── PENDING / réseau / inconnu : aucun mouvement financier ──────────────
    const pendingStates = { pending: 'provider_pending', network_error: 'provider_pending', unknown: 'provider_pending' };
    tx.update(wdRef, {
      ...baseUpdate,
      status: wd.status === 'processing' ? pendingStates[verdict.outcome] || 'provider_pending' : wd.status,
      providerStatus: verdict.providerStatus || wd.providerStatus || null,
      settlementConfirmed: false,
      autoRetryBlocked: true,
      ...(verdict.outcome === 'unknown' ? { needsReview: true, anomaly: 'unknown_provider_status' } : {}),
    });
    return { applied: false, state: verdict.outcome === 'pending' ? 'still_pending' : `unresolved_${verdict.outcome}` };
  });

  for (const [event, severity] of anomalies) {
    await logSecurityEvent('system', event, severity, `Retrait ${withdrawId} : ${event}`);
  }
  if (result.applied) {
    await logAudit({
      userId: result.userId, userType: result.userType,
      action: result.state === 'settled' ? 'withdrawal_settled' : 'withdrawal_compensated',
      targetId: withdrawId, amount: result.amount, status: result.state,
    });
  }
  return result;
}

/**
 * Traite un événement de webhook déjà authentifié. Conserve à l'identique les
 * garanties existantes : transaction Firestore atomique, idempotence par
 * re-lecture dans la transaction, rejet des transactions expirées, écriture de
 * l'historique. Ajoute : montant vérifié, statut inconnu explicite, txId
 * invalide rejeté, trace de vérification indépendante.
 */
async function processFeexPayWebhookEvent({
  db, admin, body, nowMs = Date.now(), maxAgeMs = DEFAULT_MAX_AGE_MS,
  collectionFor, logAudit = async () => {}, logSecurityEvent = async () => {},
  verifier = null, strictAmount = STRICT_AMOUNT_VERIFICATION,
}) {
  const txId = extractTransactionId(body);
  if (!txId) {
    return { httpStatus: 400, outcome: 'invalid_reference', payload: { error: 'ID transaction manquant' } };
  }

  const txRef = db.collection('wallet_transactions').doc(txId);
  const txSnap = await txRef.get();
  if (!txSnap.exists) {
    return { httpStatus: 404, outcome: 'unknown_transaction', payload: { error: 'Transaction introuvable' } };
  }
  const tx = txSnap.data();

  const createdAt = tx.createdAt?.toDate ? tx.createdAt.toDate() : null;
  if (createdAt) {
    const ageMs = nowMs - createdAt.getTime();
    if (ageMs > maxAgeMs) {
      await logSecurityEvent(tx.userId, 'webhook_replay_attempt', 'high',
        `Webhook pour transaction ${txId} vieille de ${Math.floor(ageMs / 3600000)}h`);
      return { httpStatus: 400, outcome: 'expired', payload: { error: 'Transaction expirée' } };
    }
  }

  if (tx.credited === true || tx.status === 'completed') {
    return { httpStatus: 200, outcome: 'already_processed', payload: { message: 'Déjà traité' } };
  }

  const classified = classifyPaymentStatus(body?.status);

  // ── Statut inconnu : ne jamais créditer, ne jamais passer sous silence ──
  if (classified.kind === 'unknown') {
    await logSecurityEvent(tx.userId, 'webhook_unknown_status', 'medium',
      `Statut FeexPay non reconnu pour ${txId} : "${classified.normalized || '(vide)'}"`);
    return {
      httpStatus: 200, outcome: 'unknown_status',
      payload: { message: 'Statut non reconnu — transaction laissée en attente' },
    };
  }

  // ── Échec / annulation ────────────────────────────────────────────────────
  if (classified.kind === 'failure') {
    const finalStatus = ['CANCELLED', 'CANCELED'].includes(classified.normalized) ? 'cancelled' : 'failed';
    await db.runTransaction(async (firestoreTx) => {
      const currentSnap = await firestoreTx.get(txRef);
      if (!currentSnap.exists) return;
      const current = currentSnap.data();
      if (current.credited === true || current.status === 'completed') return;
      firestoreTx.update(txRef, {
        status: finalStatus,
        validatedAt: admin.firestore.FieldValue.serverTimestamp(),
        failureReason: body?.reason || null,
        feexpayPhone: body?.phoneNumber || null,
      });
    });
    return { httpStatus: 200, outcome: finalStatus, payload: { message: 'OK' } };
  }

  // ── Succès annoncé : contrôler le montant AVANT tout crédit ───────────────
  const amountCheck = verifyPaidAmount({ expectedAmount: tx.amount, body, strict: strictAmount });
  if (!amountCheck.ok) {
    await logSecurityEvent(tx.userId, 'webhook_amount_mismatch', 'high',
      `Montant incohérent sur ${txId} (${amountCheck.reason})`);
    await txRef.update({ status: 'error', errorMessage: `amount_check:${amountCheck.reason}` });
    return {
      httpStatus: 400, outcome: 'amount_rejected',
      payload: { error: 'Montant incohérent' }, reason: amountCheck.reason,
    };
  }

  // ── Vérification serveur OBLIGATOIRE — FAIL CLOSED ────────────────────────
  // Le webhook n'est qu'une NOTIFICATION : même s'il annonce SUCCESSFUL avec
  // le montant exact, il ne suffit jamais à créditer. La seule source de
  // vérité financière est la réponse de l'endpoint officiel
  // GET /api/transactions/public/single/status/{reference}.
  // Aucun repli n'existe : pas de vérificateur configuré = aucun crédit.
  if (!verifier || typeof verifier.confirmPayment !== 'function') {
    await logSecurityEvent(tx.userId, 'webhook_verifier_unavailable', 'high',
      `Vérification serveur indisponible pour ${txId} — crédit refusé`);
    return {
      httpStatus: 503, outcome: 'verification_unavailable',
      payload: { error: 'Vérification indisponible' }, reason: 'verifier_not_configured',
    };
  }

  const confirmation = await verifier.confirmPayment({
    txId, expectedAmount: tx.amount,
  });
  if (!confirmation?.confirmed) {
    await logSecurityEvent(tx.userId, 'webhook_verification_failed', 'high',
      `Vérification serveur refusée pour ${txId} (${confirmation?.reason || 'inconnue'})`);
    return {
      httpStatus: 400, outcome: 'verification_failed',
      payload: { error: 'Paiement non confirmé' }, reason: confirmation?.reason || 'unconfirmed',
    };
  }
  const independentlyVerified = true;

  const creditedNow = await db.runTransaction(async (firestoreTx) => {
    const currentSnap = await firestoreTx.get(txRef);
    if (!currentSnap.exists) throw new Error(`Transaction ${txId} introuvable`);
    const current = currentSnap.data();
    if (current.credited === true || current.status === 'completed') return false;

    const colName = collectionFor(current.userType);
    const userRef = db.collection(colName).doc(current.userId);
    const userSnap = await firestoreTx.get(userRef);
    if (!userSnap.exists) throw new Error(`Utilisateur ${current.userId} introuvable`);

    const currentWallet = userSnap.data().wallet || 0;
    firestoreTx.update(userRef, {
      wallet: currentWallet + current.amount,
      lastRechargeAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    firestoreTx.update(txRef, {
      status: 'completed',
      credited: true,
      validatedAt: admin.firestore.FieldValue.serverTimestamp(),
      feexpayOperator: body?.reseau || body?.operator || null,
      feexpayPhone: body?.phoneNumber || null,
      feexpayRef: body?.ref_operator || body?.reference || null,
      amountVerified: amountCheck.verified,
      independentlyVerified,
    });
    const histRef = db.collection(colName).doc(current.userId)
      .collection('wallet_transactions').doc();
    firestoreTx.set(histRef, {
      type: 'recharge',
      amount: current.amount,
      description: `Recharge FeexPay ${(current.paymentMethod || '').toUpperCase()} — ${current.amount} FCFA`,
      provider: 'FeexPay',
      txId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });

  if (!creditedNow) {
    return { httpStatus: 200, outcome: 'already_processed', payload: { message: 'Déjà traité' } };
  }
  await logAudit({
    userId: tx.userId, userType: tx.userType, action: 'wallet_credited',
    targetId: txId, amount: tx.amount, status: 'success',
  });
  return {
    httpStatus: 200, outcome: 'credited',
    payload: { message: 'OK' }, amountVerified: amountCheck.verified, independentlyVerified,
  };
}

/**
 * Compense un retrait dont l'échec est PROUVÉ (jamais un résultat ambigu).
 * Idempotent : la compensation n'a lieu que si la demande est encore
 * `processing` et n'a pas déjà été compensée.
 */
async function compensateFailedWithdrawal({
  db, admin, withdrawId, collectionFor, logAudit = async () => {}, reason = 'provider_rejected',
}) {
  return db.runTransaction(async (firestoreTx) => {
    const wdRef = db.collection('withdrawal_requests').doc(withdrawId);
    const wdSnap = await firestoreTx.get(wdRef);
    if (!wdSnap.exists) return { compensated: false, reason: 'not_found' };
    const wd = wdSnap.data();
    if (wd.compensated === true || wd.status !== 'processing') {
      return { compensated: false, reason: 'already_settled' };
    }

    const colName = collectionFor(wd.userType);
    const userRef = db.collection(colName).doc(wd.userId);
    const userSnap = await firestoreTx.get(userRef);
    if (!userSnap.exists) return { compensated: false, reason: 'user_not_found' };

    const wallet = userSnap.data().wallet || 0;
    firestoreTx.update(userRef, { wallet: wallet + wd.amount });
    firestoreTx.update(wdRef, {
      status: 'failed_refunded',
      compensated: true,
      compensationReason: reason,
      compensatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const histRef = db.collection(colName).doc(wd.userId)
      .collection('wallet_transactions').doc();
    firestoreTx.set(histRef, {
      type: 'refund',
      amount: wd.amount,
      description: `Remboursement retrait échoué — ${wd.amount} FCFA`,
      withdrawId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await logAudit({
      userId: wd.userId, userType: wd.userType, action: 'withdrawal_compensated',
      targetId: withdrawId, amount: wd.amount, status: 'refunded',
    });
    return { compensated: true, amount: wd.amount };
  });
}

module.exports = {
  PAYMENT_SUCCESS_STATUSES,
  PAYMENT_FAILURE_STATUSES,
  PAID_AMOUNT_FIELD_CANDIDATES,
  EXPECTED_CURRENCY,
  STRICT_AMOUNT_VERIFICATION,
  PAYOUT_ENDPOINTS,
  PAYOUT_API_BASE,
  PAYOUT_PATH,
  PAYOUT_MIN_AMOUNT,
  PAYOUT_MOTIF_MAX_LENGTH,
  UNCERTAIN_RETRY_BLOCK_MS,
  COLLECT_UNCERTAIN_STATUS,
  sanitizeProviderMessage,
  extractProviderError,
  classifyCollectInitiationFailure,
  buildInitiationFailureLog,
  classifyPaymentStatus,
  extractTransactionId,
  isAuthorizedWebhookCall,
  extractPaidAmount,
  verifyPaidAmount,
  resolvePayoutEndpoint,
  sanitizePayoutMotif,
  assertWithdrawalCanStart,
  classifyPayoutInitiation,
  applyPayoutStatus,
  processFeexPayWebhookEvent,
  compensateFailedWithdrawal,
};
