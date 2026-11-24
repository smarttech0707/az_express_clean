'use strict';

// Mission 7E-98 (lot 2D-1), durci par 7E-100 (C1 à C6) puis 7E-103 (D-1, D-2, D-6, décisions 7E-102) — obligations financières qui empêchent la quarantaine ou l'anonymisation d'un compte.
//
// Prédicat PUR : il n'accède ni à Firestore, ni au réseau, ni à l'horloge ; l'appelant lui fournit des documents déjà lus
// (commandes, règlements de transfert, signalements de rapprochement). Même entrée => même sortie, entrées jamais modifiées.
//
// Politique générale : FAIL-CLOSED. Un statut inconnu, un champ de type inattendu, un état contradictoire, une liste
// manquante ou tronquée, un document sans lien avec le compte => obligation « ambiguë » BLOQUANTE, jamais « réglée ».
// Une absence n'est certaine que si l'appelant a fourni la liste (tableau, éventuellement vide) ET la preuve de couverture
// `reads.<liste>.queries` : une entrée { key, id, limit, size } pour CHAQUE requête exigée du rôle, avec limit <= READ_LIMIT
// et size < limit. Une requête qui atteint sa limite impose une revue manuelle (aucune pagination dans une transaction).
// Aucun texte provenant d'un document n'est jamais recopié : libellés et statuts passent par des listes blanches.
//
// Ce module ne crédite, ne débite et ne règle rien : il décrit seulement ce qui reste à régler. Il n'est branché sur aucun
// des inspecteurs (accountDeletion.js, accountDeletionScope.js, manualAccountDeletion.js) : intégration prévue en 2D-2.
// Périmètre : documents de la collection `orders`, `transfer_settlements` et `reconciliation_flags` (les autres collections
// de commandes restent traitées par leurs inspecteurs).

const CURRENCY = 'XOF';
const VERSION = 1;
const MAX_SNAPSHOT_ITEMS = 50;

// Statuts de `orders` : actifs (opération non terminée) et terminaux CONNUS. L'ensemble terminal est choisi par chaque
// appelant (C6) : aucun défaut permissif, un statut hors de son ensemble et hors des actifs est « inconnu » => ambigu.
const ACTIVE_STATUSES = Object.freeze(['pending', 'broadcast', 'assigned', 'accepted', 'picked_up']);
const KNOWN_TERMINAL_STATUSES = Object.freeze(['delivered', 'cancelled', 'expired', 'completed', 'refunded', 'failed_refunded', 'failed', 'rejected', 'declined', 'closed']);
// Ensembles réellement utilisés aujourd'hui par les inspecteurs (copiés tels quels, vérifiés par test contre le source) :
// l'intégration 2D-2 doit passer l'ensemble de l'inspecteur concerné, jamais un ensemble plus large.
const INSPECTOR_TERMINAL_STATUSES = Object.freeze({
  accountDeletion: Object.freeze(['delivered', 'cancelled', 'expired', 'completed', 'refunded', 'failed_refunded', 'failed', 'rejected']),
  accountDeletionScope: Object.freeze(['delivered', 'cancelled', 'expired', 'completed', 'refunded', 'failed_refunded', 'failed', 'rejected', 'closed']),
  manualAccountDeletion: Object.freeze(['delivered', 'cancelled', 'expired', 'completed', 'refunded', 'failed_refunded', 'failed', 'rejected', 'declined', 'closed']),
});

// settlementStatus (orders) : écrit par deliverOrderCF / driverTransfer / transferSettlement.
const SETTLEMENT_STATUS = Object.freeze({ OPEN: ['pending_admin_review', 'cash_pending'], CLOSED: ['settled'] });
// transfer_settlements/{orderId}.status : 'pending_review' (création), 'cash_pending' (approuvé en espèces), 'settled'.
const TRANSFER_SETTLEMENT_STATUS = Object.freeze({ OPEN: ['pending_review', 'cash_pending'], CLOSED: ['settled'] });
// deliveryFeeHold.status (cancelOrderTx / adminBilling).
const FEE_HOLD_STATUS = Object.freeze({ OPEN: ['pending_admin_review'], CLOSED: ['resolved'] });
// cancelRequestAfterPickup.status (orderActions / adminOrderDisputes).
const CANCEL_REQUEST_STATUS = Object.freeze({
  OPEN: ['pending_admin_review'],
  CLOSED: ['resolved_delivery_confirmed', 'resolved_without_closure', 'resolved_cancelled', 'resolved_partial_refund'],
});
// cashRemittance.status (deliverOrderCF / partnerOrderActions).
const CASH_REMITTANCE_STATUS = Object.freeze(['pending', 'declared', 'confirmed', 'disputed', 'resolved']);
// cashPayment (cashPayment.js).
const CASH_PAYMENT_STATUS = Object.freeze(['confirmed', 'non_payment_declared', 'unknown']);
const CASH_PAYMENT_VERIFICATION = Object.freeze(['not_required', 'pending_review', 'confirmed_unpaid', 'refuted']);
// reconciliation_flags.status : 'open' (à traiter), 'recorded' (reliquat arrêté par décision), 'reviewed' / 'resolved' (clos).
// L4.6 : 'cleared' = verrou opérationnel LEVÉ (clearBeneficiaryReview, données L4 historiques) ; ce n'est JAMAIS une clôture de créance.
const FLAG_STATUS = Object.freeze({ OPEN: ['open'], DECIDED: ['recorded'], CONTESTED: ['contested'], CLOSED: ['reviewed', 'resolved'], LOCK_LIFTED: ['cleared'] });
// Limite maximale d'une requête de lecture (convention des inspecteurs : limit(201), 201 documents = lecture tronquée).
const READ_LIMIT = 201;

const TYPES = Object.freeze({
  INVALID_INPUT: 'invalid_input',
  INPUT_INCOMPLETE: 'input_incomplete',
  UNRELATED_DOCUMENT: 'unrelated_document',
  EVALUATION_ERROR: 'evaluation_error',
  OPERATION_OPEN: 'operation_open',
  REFUND_PENDING: 'refund_pending',
  REVIEW_OPEN: 'review_open',
  PAYMENT_PENDING: 'payment_pending',
  UNPAID_DELIVERED_WALLET: 'unpaid_delivered_wallet',
  SETTLEMENT_HELD: 'settlement_held',
  HELD_DRIVER_EARNING: 'held_driver_earning',
  DELIVERY_FEE_HELD: 'delivery_fee_held',
  POST_PICKUP_CANCEL_OPEN: 'post_pickup_cancel_open',
  CASH_REMITTANCE_OPEN: 'cash_remittance_open',
  MERCHANT_CASH_UNSETTLED: 'merchant_cash_unsettled',
  CASH_PAYMENT_REVIEW: 'cash_payment_review',
  TRANSFER_SETTLEMENT_OPEN: 'transfer_settlement_open',
  RECONCILIATION_FLAG_OPEN: 'reconciliation_flag_open',
  RECONCILIATION_RECORDED: 'reconciliation_recorded',
  V2_WALLET_DEBIT: 'v2_wallet_debit_unreconciled',
  WALLET_DEBIT_QUOTE: 'quote_wallet_debit_unreconciled',
  LEGACY_WALLET_UNPROVEN: 'legacy_wallet_payment_unproven',
});

// state : 'open' (à régler), 'review' (retenu pour revue humaine), 'ambiguous' (indéterminé, fail-closed), 'retained'
// (décision finale conservée pour la traçabilité, NON bloquante), 'manual_review' (7E-107 : paiement wallet historique dont
// l'écrivain ne garantit pas de journal ; NI dette, NI règlement prouvé ; NON bloquant, listé séparément pour la revue humaine).
const STATE = Object.freeze({
  OPEN: 'open', REVIEW: 'review', AMBIGUOUS: 'ambiguous', RETAINED: 'retained', MANUAL_REVIEW: 'manual_review',
});
const CODE = Object.freeze({ NONE: 'none', PENDING: 'financial_obligation_pending', AMBIGUOUS: 'financial_state_ambiguous' });

const ROLE_ALIASES = Object.freeze({
  client: 'client', clients: 'client',
  livreur: 'driver', driver: 'driver', livreurs: 'driver',
  pharmacie: 'partner', pharmacy: 'partner', seller: 'partner', vendeur: 'partner', boulangerie: 'partner',
  restaurant: 'partner', partner: 'partner', partenaire: 'partner',
});
const PARTY_FIELDS = Object.freeze({
  client: ['clientId'],
  driver: ['driverId'],
  partner: ['sellerId', 'pharmacieId', 'restaurantId', 'boulangerieId'],
});

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = Number.isSafeInteger;
const isStr = (v) => typeof v === 'string' && v.length > 0;
const amountOrNull = (v) => (isInt(v) && v >= 0 ? v : null);
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k) && o[k] !== undefined && o[k] !== null;

function normalizeRole(role) {
  return typeof role === 'string' ? (ROLE_ALIASES[role.toLowerCase()] || null) : null;
}

// ── Libellés (C3) ───────────────────────────────────────────────────────────────────────────────────────────────
// Aucune chaîne issue d'un document n'atteint un résultat : seules ces listes blanches sont reproduites, tout le reste
// devient 'unrecognized'. Les identifiants techniques (refId/orderId) sont bornés et limités à un jeu de caractères sûr.
const FLAG_TYPES = Object.freeze([
  'cash_payment_review', 'cash_shortfall', 'commission_untraced', 'partner_credit_missing', 'seller_review',
  'driver_advance_unreimbursed', 'ekbine_cancel_unproven_debit', 'ekbine_confirm_unproven_debit', 'beneficiary_account_closed',
  'beneficiary_closed', 'beneficiary_closed_refused',
]);
const REVIEW_REASONS = Object.freeze(['beneficiary_account_closed', 'beneficiary_closed', 'beneficiary_credit_omitted']);
const SOURCES = Object.freeze(['order', 'transfer_settlement', 'reconciliation_flag', 'input']);
const PARTIES = Object.freeze(['client', 'driver', 'partner', 'unknown']);
const STATUS_LABELS = new Set([
  ...ACTIVE_STATUSES, ...KNOWN_TERMINAL_STATUSES, ...SETTLEMENT_STATUS.OPEN, ...SETTLEMENT_STATUS.CLOSED,
  ...TRANSFER_SETTLEMENT_STATUS.OPEN, ...TRANSFER_SETTLEMENT_STATUS.CLOSED, ...FLAG_STATUS.OPEN, ...FLAG_STATUS.DECIDED, ...FLAG_STATUS.CONTESTED, ...FLAG_STATUS.CLOSED, ...FLAG_STATUS.LOCK_LIFTED,
]);
const LISTS = Object.freeze(['orders', 'settlements', 'flags']);
const REASONS = new Set([
  'input_not_an_object', 'unknown_role', 'account_ids_missing', 'unexpected_failure', 'terminal_statuses_invalid',
  'legacy_option_unsupported', 'reads_missing', 'reads_unknown_key', 'truncated_flag_invalid_or_set',
  ...LISTS.flatMap((n) => [`${n}_not_provided`, `${n}_not_an_array`, `${n}_truncated`, `${n}_coverage_unproven`,
    `${n}_read_size_mismatch`, `${n}_entry_without_id`, `${n}_entry_evaluation_failed`, `${n}_duplicate_document_id`]),
  'order_not_an_object', 'order_not_linked_to_account', 'unknown_or_unreadable_status', 'active_or_unresolved_operation',
  'refund_pending_not_boolean', 'refund_pending', 'needs_review_not_boolean', 'needs_review',
  'payment_status_not_string', 'payment_status_pending', 'is_paid_not_boolean', 'delivered_wallet_order_unpaid',
  'delivered_wallet_order_is_paid_absent', 'delivered_order_payment_method_unknown',
  'settlement_hold_not_boolean', 'settlement_status_not_string', 'unknown_settlement_status', 'settlement_settled_but_hold_true',
  'settlement_hold_active', 'settlement_status_pending_admin_review', 'settlement_status_cash_pending',
  'held_driver_earning_invalid', 'held_driver_earning_not_settled',
  'delivery_fee_hold_unreadable', 'delivery_fee_hold_pending', 'unknown_delivery_fee_hold_status',
  'cancel_request_unreadable', 'cancel_request_pending_admin_review', 'unknown_cancel_request_status',
  'cash_remittance_unreadable_or_unknown_status', 'cash_remittance_amount_due_invalid', 'cash_remittance_resolution_invalid',
  'cash_remittance_confirmed_amount_invalid', 'cash_remittance_partially_confirmed', 'cash_remittance_confirmed_above_due',
  'cash_remittance_disputed', 'cash_remittance_pending', 'cash_remittance_declared',
  'merchant_cash_settled_without_confirmation', 'cash_remittance_missing_on_v2_cash_order', 'merchant_cash_settled_not_boolean',
  'merchant_cash_not_settled', 'cash_payment_unreadable_or_unknown_value', 'cash_payment_declared_unpaid_without_review',
  'cash_payment_pending_review',
  'settlement_not_an_object', 'settlement_not_linked_to_account', 'settlement_status_unreadable', 'settlement_pending_review',
  'settlement_cash_pending',
  'flag_not_an_object', 'flag_status_unreadable', 'flag_without_party', 'flag_not_linked_to_account', 'unknown_flag_status',
  'flag_contested', 'flag_parties_unreadable', 'flag_party_contradiction', 'flag_currency_invalid', 'flag_kind_unknown',
  'flag_amount_invalid', 'flag_source_journal_missing', 'flag_order_missing', 'flag_completed_contradiction',
  'flag_lock_lifted_debt_maintained', 'flag_closure_unproven',
  'flag_open', 'flag_recorded', 'flag_recorded_unproven', 'flag_reviewed_unproven', 'flag_resolved_unproven',
  ...FLAG_TYPES.map((t) => `flag_open:${t}`), 'flag_open:other', ...FLAG_TYPES.map((t) => `flag_recorded:${t}`), 'flag_recorded:other',
  ...REVIEW_REASONS.map((r) => `needs_review:${r}`),
  'result_unreadable', 'result_inconsistent', 'summary_mismatch', 'item_invalid', 'unrecognized_reason',
]);
const ID_PATTERN = /^[A-Za-z0-9_.:-]{1,128}$/;
// Empreinte FNV-1a 32 bits d'un identifiant NON fiable : deux identifiants invalides restent distincts (D-6) sans que
// l'identifiant d'origine (potentiellement personnel) ne soit recopié.
function fingerprint(v) {
  const text = String(v);
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}
const validId = (v) => typeof v === 'string' && ID_PATTERN.test(v) && !v.startsWith('invalid:');
const SAFE_INVALID = /^invalid:[0-9a-f]{8}$/;
// Idempotent : un identifiant déjà neutralisé n'est pas haché une seconde fois (le snapshot reprend les mêmes valeurs).
const safeId = (v) => (v == null ? null : validId(v) ? v : SAFE_INVALID.test(String(v)) ? String(v) : `invalid:${fingerprint(v)}`);
const own = (o, k) => (Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined);
const safeStatus = (v) => (typeof v !== 'string' ? null : STATUS_LABELS.has(v) ? v : 'unrecognized');
const safeReason = (v) => (typeof v === 'string' && REASONS.has(v) ? v : 'unrecognized_reason');
const flagTypeLabel = (f) => {
  const t = f.type !== undefined && f.type !== null ? f.type : f.kind;
  return FLAG_TYPES.includes(t) ? t : 'other';
};
const TYPE_VALUES = new Set(Object.values(TYPES));
const STATE_VALUES = new Set(Object.values(STATE));

// Rôle de partenaire -> champ propriétaire spécifique des commandes (en plus de `sellerId`), comme readDeletionScope.
function partnerKind(roleRaw) {
  const r = typeof roleRaw === 'string' ? roleRaw.toLowerCase() : '';
  if (r === 'pharmacie' || r === 'pharmacy') return 'pharmacieId';
  if (r === 'restaurant') return 'restaurantId';
  if (r === 'boulangerie') return 'boulangerieId';
  return null;
}

// Commande payée par wallet et livrée (hors boutique, dont le vrai paiement vit sur `boutique_orders`).
// Générations d'écrivain (7E-107, voir le rapport) :
//  - 'v2'     : partnerOrderQuote (amountsVersion 2) ; journal déterministe `order_<id>`, montant = totalAmount.
//  - 'quote'  : createCatalogOrderFromQuoteCF / createOrderFromQuoteCF (champ `tariffQuoteId`) ; même journal `order_<id>`,
//               écrit dans la MÊME transaction que la création ; montant = budget + shoppingBudget.
//  - 'legacy' : création client Flutter (débit + `lastPaidOrderId`, aucun journal garanti) ou payOrderFromWalletCF (journal à
//               identifiant automatique écrit APRÈS la transaction) : aucune preuve par document n'existe => revue manuelle.
const paidWalletDelivered = (o) => o.status === 'delivered' && o.type !== 'boutique' && o.paymentMethod === 'wallet' && o.isPaid === true;
const walletGeneration = (o) => (o.amountsVersion === 2 ? 'v2' : isStr(o.tariffQuoteId) ? 'quote' : 'legacy');
const needsDebitProof = (o) => paidWalletDelivered(o) && walletGeneration(o) !== 'legacy';

// ── Créances économiques (D-6) ───────────────────────────────────────────────────────────────────────────────────
// Clé = orderId + créance. Plusieurs symptômes d'une même créance (ex. commande impayée + revue bénéficiaire + signalement)
// partagent la clé : ils ne sont comptés qu'une fois comme obligation économique. Sans orderId fiable => aucune clé.
const CLAIMS = Object.freeze([
  'client_payment', 'driver_earning', 'delivery_fee', 'cash_remittance', 'client_cash', 'refund', 'post_pickup_cancel', 'order_state',
  'commission', 'partner_credit', 'seller_review', 'driver_advance', 'ekbine_debit',
]);
const CLAIM_BY_TYPE = Object.freeze({
  unpaid_delivered_wallet: 'client_payment', v2_wallet_debit_unreconciled: 'client_payment', quote_wallet_debit_unreconciled: 'client_payment',
  legacy_wallet_payment_unproven: 'client_payment',
  settlement_held: 'driver_earning', held_driver_earning: 'driver_earning', transfer_settlement_open: 'driver_earning',
  delivery_fee_held: 'delivery_fee', cash_remittance_open: 'cash_remittance', merchant_cash_unsettled: 'cash_remittance',
  cash_payment_review: 'client_cash', refund_pending: 'refund', post_pickup_cancel_open: 'post_pickup_cancel',
  review_open: 'order_state', payment_pending: 'order_state', operation_open: 'order_state',
});
const FLAG_CLAIM = Object.freeze({
  cash_shortfall: 'cash_remittance', beneficiary_account_closed: 'client_payment', cash_payment_review: 'client_cash',
  commission_untraced: 'commission', partner_credit_missing: 'partner_credit', seller_review: 'seller_review',
  driver_advance_unreimbursed: 'driver_advance', ekbine_cancel_unproven_debit: 'ekbine_debit', ekbine_confirm_unproven_debit: 'ekbine_debit',
  // L4.6 : commission non rendue à un livreur fermé = créance de commission ; la trace d'un refus n'est pas une créance chiffrée.
  beneficiary_closed: 'commission',
});

// ── Résolutions admises par type et niveau de validation minimal (décisions 7E-102) ──────────────────────────────
// Niveau 1 : constat prouvé (un super-admin) · niveau 2 : deux validations indépendantes · niveau 3 : niveau 2 + accord écrit
// du créancier. Abandon de créance : uniquement pour une créance d'AZ Express (WAIVER_RESOLUTIONS).
const RESOLUTIONS = Object.freeze({
  commission_untraced: Object.freeze({ verified_no_debit: 1, refunded_by_ledger: 1, waived_platform_claim: 3 }),
  partner_credit_missing: Object.freeze({ paid_to_partner_ledger: 1, paid_out_of_system: 2 }),
  seller_review: Object.freeze({ reviewed_no_action: 2, adjusted_by_ledger: 2 }),
  driver_advance_unreimbursed: Object.freeze({ reimbursed_by_ledger: 1, reimbursed_out_of_system: 2 }),
  ekbine_cancel_unproven_debit: Object.freeze({ debit_proven_and_settled: 1, debit_disproved: 2, refunded_by_ledger: 2 }),
  ekbine_confirm_unproven_debit: Object.freeze({ debit_proven_and_settled: 1, debit_disproved: 2, refunded_by_ledger: 2 }),
  cash_shortfall: Object.freeze({ recovered_in_full: 2, absorbed_by_platform: 2 }),
  beneficiary_account_closed: Object.freeze({ payment_completed: 1, beneficiary_substituted: 2 }),
  client_cash_nonpayment: Object.freeze({ refuted_after_contest: 2, paid_by_client_out_of_system: 2 }),
});
// Résolutions envisagées par 7E-102 ou 7E-103 dont la politique métier n'est pas définie : volontairement ABSENTES de
// RESOLUTIONS, donc refusées (`flag_resolution_not_allowed`) et bloquantes. Toute autre valeur inconnue suit la même règle.
const UNAUTHORIZED_RESOLUTIONS = Object.freeze([
  'closed_by_contract', 'no_claim_established', 'waived_by_partner', 'waived_by_driver', 'written_off_by_platform',
  'partner_unreachable_held', 'order_payment_waived_by_platform', 'paid_out_of_system_client',
]);
// Types dont l'écrivain enregistre un décideur initial humain : l'approbation N2/N3 doit venir d'une autre personne.
const ORIGIN_DECIDER_REQUIRED = Object.freeze([
  'cash_shortfall', 'seller_review', 'driver_advance_unreimbursed', 'client_cash_nonpayment',
  'ekbine_cancel_unproven_debit', 'ekbine_confirm_unproven_debit',
]);
// Règlements « hors système » : en plus des deux validations (N2), une preuve de paiement vérifiée côté serveur, concordant avec
// la créance (montant, bénéficiaire, commande) et immuable. Une simple référence textuelle n'est jamais une preuve.
const OUT_OF_SYSTEM_RESOLUTIONS = Object.freeze(['paid_out_of_system', 'reimbursed_out_of_system', 'paid_by_client_out_of_system']);
// Identifiant de requête idempotent réel (contrainte de reviewNonPayment : 16 à 128 caractères).
const REQUEST_ID_PATTERN = /^[A-Za-z0-9_.:-]{16,128}$/;
const ACTOR_PATTERN = /^[A-Za-z0-9_.:-]{1,128}$/;

// Réasons ajoutées par 7E-103.
for (const r of [
  'wallet_debits_invalid', 'decisions_invalid', 'v2_wallet_debit_unverified', 'v2_wallet_debit_missing', 'v2_wallet_debit_mismatch',
  'v2_amounts_inconsistent', 'cash_nonpayment_case_review', 'cash_nonpayment_case_closed', 'flag_contested', 'flag_recorded_open',
  'flag_decision_unverified', 'flag_resolution_not_allowed', 'evidence_invalid', 'flag_level3_unavailable',
  'quote_amounts_inconsistent', 'quote_wallet_debit_unverified', 'quote_wallet_debit_missing', 'quote_wallet_debit_mismatch',
  'legacy_wallet_payment_unproven', 'flag_reviewed:cash_payment_review',
  ...FLAG_TYPES.map((t) => `flag_resolved:${t}`),
  ...LISTS.flatMap((n) => [`${n}_queries_incomplete`, `${n}_query_invalid`, `${n}_query_duplicate`, `${n}_invalid_document_id`]),
]) REASONS.add(r);

function item(base) {
  const type = TYPE_VALUES.has(base.type) ? base.type : TYPES.EVALUATION_ERROR;
  const state = STATE_VALUES.has(base.state) ? base.state : STATE.AMBIGUOUS;
  const claimRaw = base.claim !== undefined ? base.claim : own(CLAIM_BY_TYPE, type);
  const claim = CLAIMS.includes(claimRaw) ? claimRaw : null;
  const orderId = safeId(base.orderId);
  return {
    type,
    state,
    blocking: state !== STATE.RETAINED && state !== STATE.MANUAL_REVIEW,
    source: SOURCES.includes(base.source) ? base.source : 'input',
    refId: safeId(base.refId),
    orderId,
    party: PARTIES.includes(base.party) ? base.party : 'unknown',
    amount: amountOrNull(base.amount),
    currency: CURRENCY,
    status: safeStatus(base.status),
    reason: safeReason(base.reason),
    claim,
    economicKey: claim && validId(orderId) ? `${orderId}|${claim}` : null,
  };
}

// Évalue UNE commande. Retourne la liste (éventuellement vide) des éléments financiers non réglés ou ambigus.
function evaluateOrder(order, ctx) {
  const { role, ids, terminal, debits, decisions, evidence } = ctx;
  const out = [];
  const refId = order.id;
  const o = order.data;
  const mk = (type, state, reason, extra = {}) => out.push(item({
    type, state, reason, source: 'order', refId, orderId: refId, party: role, status: o.status, ...extra,
  }));
  const ambiguous = (type, reason, extra) => mk(type, STATE.AMBIGUOUS, reason, extra);

  if (!isObject(o)) return [item({ type: TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'order_not_an_object', source: 'order', refId, orderId: refId, party: role })];

  // Lien avec le compte : l'appelant interroge par champ propriétaire ; un document étranger est un défaut d'appel.
  const related = PARTY_FIELDS[role].some((f) => isStr(o[f]) && ids.includes(o[f]));
  if (!related) return [item({ type: TYPES.UNRELATED_DOCUMENT, state: STATE.AMBIGUOUS, reason: 'order_not_linked_to_account', source: 'order', refId, orderId: refId, party: role, status: o.status })];

  const status = o.status;
  const delivered = status === 'delivered';
  const paymentMethod = o.paymentMethod;
  const amountsV2 = o.amountsVersion === 2;

  // ── Statut : inconnu => ambigu ; actif => opération non terminée ──────────────────────────────────────────────
  if (typeof status !== 'string' || !(terminal.has(status) || ACTIVE_STATUSES.includes(status))) {
    ambiguous(TYPES.OPERATION_OPEN, 'unknown_or_unreadable_status');
  } else if (!terminal.has(status)) {
    mk(TYPES.OPERATION_OPEN, STATE.OPEN, 'active_or_unresolved_operation');
  }

  // ── Drapeaux génériques déjà utilisés par les inspecteurs (types strictement booléens / chaîne) ──────────────
  if (has(o, 'refundPending')) {
    if (typeof o.refundPending !== 'boolean') ambiguous(TYPES.REFUND_PENDING, 'refund_pending_not_boolean');
    else if (o.refundPending) mk(TYPES.REFUND_PENDING, STATE.OPEN, 'refund_pending', { amount: amountOrNull(o.budget) });
  }
  if (has(o, 'needsReview')) {
    if (typeof o.needsReview !== 'boolean') ambiguous(TYPES.REVIEW_OPEN, 'needs_review_not_boolean');
    else if (o.needsReview) mk(TYPES.REVIEW_OPEN, STATE.REVIEW, REVIEW_REASONS.includes(o.reviewReason) ? `needs_review:${o.reviewReason}` : 'needs_review');
  }
  if (has(o, 'paymentStatus')) {
    if (typeof o.paymentStatus !== 'string') ambiguous(TYPES.PAYMENT_PENDING, 'payment_status_not_string');
    else if (o.paymentStatus === 'pending') mk(TYPES.PAYMENT_PENDING, STATE.OPEN, 'payment_status_pending');
  }

  // ── Commande livrée non payée (règlement wallet différé, ex. pharmacie) ───────────────────────────────────────
  // Seule exclusion certaine : `boutique` (isPaid reste false, le vrai paiement vit sur boutique_orders). Une commande v2
  // n'est PAS réglée du seul fait d'amountsVersion 2 : le débit est fait à la création mais isPaid doit alors valoir true
  // (partnerOrderReconciliation : V2_WALLET_NOT_MARKED_PAID, gravité haute).
  if (delivered && o.type !== 'boutique') {
    if (has(o, 'isPaid') && typeof o.isPaid !== 'boolean') {
      ambiguous(TYPES.UNPAID_DELIVERED_WALLET, 'is_paid_not_boolean');
    } else if (o.isPaid !== true) {
      if (paymentMethod === 'wallet') {
        if (o.isPaid === false) {
          mk(TYPES.UNPAID_DELIVERED_WALLET, STATE.OPEN, 'delivered_wallet_order_unpaid', { amount: amountOrNull(o.budget) });
        } else {
          // Sans champ isPaid : deliverOrderCF la traite comme non payée, cancelOrderTx comme payée => jamais réglée
          // implicitement (aucune dérogation tant qu'une preuve par journal wallet n'est pas définie).
          ambiguous(TYPES.UNPAID_DELIVERED_WALLET, 'delivered_wallet_order_is_paid_absent', { amount: amountOrNull(o.budget) });
        }
      } else if (paymentMethod !== 'cash') {
        ambiguous(TYPES.UNPAID_DELIVERED_WALLET, 'delivered_order_payment_method_unknown');
      }
    }
  }

  // ── Commande wallet payée (client) : preuve par journal selon la génération de l'écrivain ─────────────────────────
  if (role === 'client' && paidWalletDelivered(o)) {
    const gen = walletGeneration(o);
    if (gen === 'legacy') {
      // Ni dette inventée, ni règlement déclaré : le paiement n'est pas prouvable par document. Non bloquant, listé à part.
      mk(TYPES.LEGACY_WALLET_UNPROVEN, STATE.MANUAL_REVIEW, 'legacy_wallet_payment_unproven');
    } else {
      const isV2 = gen === 'v2';
      const type = isV2 ? TYPES.V2_WALLET_DEBIT : TYPES.WALLET_DEBIT_QUOTE;
      const prefix = isV2 ? 'v2' : 'quote';
      let total;
      if (isV2) {
        total = o.totalAmount;
        const ok = isInt(o.productAmount) && o.productAmount > 0 && isInt(o.deliveryFee) && o.deliveryFee > 0 && isInt(total) && o.productAmount + o.deliveryFee === total;
        if (!ok) total = undefined;
      } else if (isInt(o.budget) && o.budget > 0 && isInt(o.shoppingBudget) && o.shoppingBudget >= 0) {
        total = o.budget + o.shoppingBudget;
      }
      if (total === undefined) {
        ambiguous(type, `${prefix}_amounts_inconsistent`);
      } else {
        // Journal absent ou divergent => REVUE (bloquante). Journal non fourni => défaut d'appel (ambigu, bloquant).
        const entry = own(debits, `order_${refId}`);
        if (!entry) ambiguous(type, `${prefix}_wallet_debit_unverified`, { amount: total });
        else if (entry.exists !== true) mk(type, STATE.REVIEW, `${prefix}_wallet_debit_missing`, { amount: total });
        else if (!isObject(entry.data) || entry.data.type !== 'payment' || entry.data.orderId !== refId || entry.data.amount !== total) {
          mk(type, STATE.REVIEW, `${prefix}_wallet_debit_mismatch`, { amount: total });
        }
      }
    }
  }

  // ── Gain livreur / frais retenus / demande d'annulation après récupération (client et livreur) ────────────────
  if (role === 'client' || role === 'driver') {
    const holdFlag = o.settlementHold;
    const sStatus = o.settlementStatus;
    if (has(o, 'settlementHold') && typeof holdFlag !== 'boolean') ambiguous(TYPES.SETTLEMENT_HELD, 'settlement_hold_not_boolean');
    else if (has(o, 'settlementStatus') && typeof sStatus !== 'string') ambiguous(TYPES.SETTLEMENT_HELD, 'settlement_status_not_string');
    else {
      const known = !has(o, 'settlementStatus') || SETTLEMENT_STATUS.OPEN.includes(sStatus) || SETTLEMENT_STATUS.CLOSED.includes(sStatus);
      if (!known) ambiguous(TYPES.SETTLEMENT_HELD, 'unknown_settlement_status', { amount: amountOrNull(o.heldDriverEarning) });
      else if (SETTLEMENT_STATUS.CLOSED.includes(sStatus) && holdFlag === true) ambiguous(TYPES.SETTLEMENT_HELD, 'settlement_settled_but_hold_true');
      else if (holdFlag === true || SETTLEMENT_STATUS.OPEN.includes(sStatus)) {
        mk(TYPES.SETTLEMENT_HELD, STATE.OPEN, holdFlag === true ? 'settlement_hold_active' : `settlement_status_${sStatus}`, { amount: amountOrNull(o.heldDriverEarning) });
      }
    }
    if (has(o, 'heldDriverEarning')) {
      const settled = has(o, 'settlementStatus') && SETTLEMENT_STATUS.CLOSED.includes(o.settlementStatus);
      if (!isInt(o.heldDriverEarning) || o.heldDriverEarning < 0) ambiguous(TYPES.HELD_DRIVER_EARNING, 'held_driver_earning_invalid');
      else if (o.heldDriverEarning > 0 && !settled) mk(TYPES.HELD_DRIVER_EARNING, STATE.OPEN, 'held_driver_earning_not_settled', { amount: o.heldDriverEarning });
    }
    if (has(o, 'deliveryFeeHold')) {
      const h = o.deliveryFeeHold;
      if (!isObject(h) || typeof h.status !== 'string') ambiguous(TYPES.DELIVERY_FEE_HELD, 'delivery_fee_hold_unreadable');
      else if (FEE_HOLD_STATUS.OPEN.includes(h.status)) mk(TYPES.DELIVERY_FEE_HELD, STATE.OPEN, 'delivery_fee_hold_pending', { amount: amountOrNull(h.amount) });
      else if (!FEE_HOLD_STATUS.CLOSED.includes(h.status)) ambiguous(TYPES.DELIVERY_FEE_HELD, 'unknown_delivery_fee_hold_status', { amount: amountOrNull(h.amount) });
    }
    if (has(o, 'cancelRequestAfterPickup')) {
      const r = o.cancelRequestAfterPickup;
      if (!isObject(r) || typeof r.status !== 'string') ambiguous(TYPES.POST_PICKUP_CANCEL_OPEN, 'cancel_request_unreadable');
      else if (CANCEL_REQUEST_STATUS.OPEN.includes(r.status)) mk(TYPES.POST_PICKUP_CANCEL_OPEN, STATE.REVIEW, 'cancel_request_pending_admin_review');
      else if (!CANCEL_REQUEST_STATUS.CLOSED.includes(r.status)) ambiguous(TYPES.POST_PICKUP_CANCEL_OPEN, 'unknown_cancel_request_status');
    }
  }

  // ── Espèces : reversement au partenaire (livreur et partenaire) ───────────────────────────────────────────────
  const cashWithMerchant = delivered && paymentMethod === 'cash' && isStr(o.sellerId) && o.type !== 'boutique' && o.sellerType !== 'boutique';
  if (role === 'driver' || role === 'partner') {
    const remittance = o.cashRemittance;
    if (has(o, 'cashRemittance')) {
      if (!isObject(remittance) || !CASH_REMITTANCE_STATUS.includes(remittance.status)) {
        ambiguous(TYPES.CASH_REMITTANCE_OPEN, 'cash_remittance_unreadable_or_unknown_status');
      } else if (!isInt(remittance.amountDue) || remittance.amountDue < 0) {
        ambiguous(TYPES.CASH_REMITTANCE_OPEN, 'cash_remittance_amount_due_invalid');
      } else if (remittance.status === 'resolved') {
        const fin = isObject(remittance.resolution) ? remittance.resolution.finalAmount : undefined;
        if (!isInt(fin) || fin < 0 || fin > remittance.amountDue) ambiguous(TYPES.CASH_REMITTANCE_OPEN, 'cash_remittance_resolution_invalid', { amount: remittance.amountDue });
      } else if (remittance.status === 'confirmed') {
        const confirmed = has(remittance, 'amountConfirmed') ? remittance.amountConfirmed : 0;
        if (!isInt(confirmed) || confirmed < 0) ambiguous(TYPES.CASH_REMITTANCE_OPEN, 'cash_remittance_confirmed_amount_invalid');
        else if (confirmed < remittance.amountDue) mk(TYPES.CASH_REMITTANCE_OPEN, STATE.OPEN, 'cash_remittance_partially_confirmed', { amount: remittance.amountDue - confirmed });
        else if (confirmed > remittance.amountDue) ambiguous(TYPES.CASH_REMITTANCE_OPEN, 'cash_remittance_confirmed_above_due', { amount: remittance.amountDue });
      } else if (remittance.status === 'disputed') {
        mk(TYPES.CASH_REMITTANCE_OPEN, STATE.REVIEW, 'cash_remittance_disputed', { amount: remittance.amountDue });
      } else {
        mk(TYPES.CASH_REMITTANCE_OPEN, STATE.OPEN, `cash_remittance_${remittance.status}`, { amount: remittance.amountDue });
      }
      const view = isObject(remittance) ? remittance.status : null;
      if (o.merchantCashSettled === true && view !== 'confirmed' && view !== 'resolved') {
        ambiguous(TYPES.MERCHANT_CASH_UNSETTLED, 'merchant_cash_settled_without_confirmation');
      }
    } else if (cashWithMerchant) {
      if (amountsV2) {
        ambiguous(TYPES.CASH_REMITTANCE_OPEN, 'cash_remittance_missing_on_v2_cash_order', { amount: amountOrNull(o.productAmount) });
      } else if (has(o, 'merchantCashSettled') && typeof o.merchantCashSettled !== 'boolean') {
        ambiguous(TYPES.MERCHANT_CASH_UNSETTLED, 'merchant_cash_settled_not_boolean');
      } else if (o.merchantCashSettled === false) {
        mk(TYPES.MERCHANT_CASH_UNSETTLED, STATE.OPEN, 'merchant_cash_not_settled');
      }
    }
  }

  // ── Non-paiement espèces déclaré par le livreur, à examiner ───────────────────────────────────────────────────
  if (has(o, 'cashPayment')) {
    const p = o.cashPayment;
    if (!isObject(p) || !CASH_PAYMENT_STATUS.includes(p.status) || !CASH_PAYMENT_VERIFICATION.includes(p.verification)) {
      ambiguous(TYPES.CASH_PAYMENT_REVIEW, 'cash_payment_unreadable_or_unknown_value');
    } else if (p.status === 'non_payment_declared' && p.verification === 'not_required') {
      ambiguous(TYPES.CASH_PAYMENT_REVIEW, 'cash_payment_declared_unpaid_without_review');
    } else if (p.verification === 'pending_review') {
      mk(TYPES.CASH_PAYMENT_REVIEW, STATE.REVIEW, 'cash_payment_pending_review');
    } else if (p.verification === 'confirmed_unpaid' && role === 'client') {
      // Cas par cas : aucune dette n'est inventée (montant null). Bloquant jusqu'à une décision exécutée qui le ferme.
      if (clientCashCaseClosed({ decisions, evidence }, refId, o)) mk(TYPES.RECONCILIATION_RECORDED, STATE.RETAINED, 'cash_nonpayment_case_closed', { claim: 'client_cash' });
      else mk(TYPES.CASH_PAYMENT_REVIEW, STATE.REVIEW, 'cash_nonpayment_case_review', { amount: null });
    }
  }
  return out;
}

function evaluateSettlement(doc, ctx) {
  const { role, ids } = ctx;
  const s = doc.data;
  const base = { source: 'transfer_settlement', refId: doc.id, orderId: isObject(s) && isStr(s.orderId) ? s.orderId : doc.id, party: role };
  if (!isObject(s)) return [item({ ...base, type: TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'settlement_not_an_object' })];
  const driverIds = Array.isArray(s.driverIds) ? s.driverIds : null;
  const involved = role === 'driver'
    ? (driverIds && driverIds.some((d) => ids.includes(d))) || (isStr(s.holderDriverId) && ids.includes(s.holderDriverId))
    : role === 'client' ? isStr(s.clientId) && ids.includes(s.clientId) : false;
  if (!involved) return [item({ ...base, type: TYPES.UNRELATED_DOCUMENT, state: STATE.AMBIGUOUS, reason: 'settlement_not_linked_to_account', status: s.status })];
  if (typeof s.status !== 'string') return [item({ ...base, type: TYPES.TRANSFER_SETTLEMENT_OPEN, state: STATE.AMBIGUOUS, reason: 'settlement_status_unreadable' })];
  const amount = amountOrNull(s.totalPaid);
  if (TRANSFER_SETTLEMENT_STATUS.OPEN.includes(s.status)) {
    return [item({ ...base, type: TYPES.TRANSFER_SETTLEMENT_OPEN, state: s.status === 'pending_review' ? STATE.REVIEW : STATE.OPEN, reason: `settlement_${s.status}`, status: s.status, amount })];
  }
  if (!TRANSFER_SETTLEMENT_STATUS.CLOSED.includes(s.status)) {
    return [item({ ...base, type: TYPES.TRANSFER_SETTLEMENT_OPEN, state: STATE.AMBIGUOUS, reason: 'unknown_settlement_status', status: s.status, amount })];
  }
  return [];
}

// Signalements de rapprochement (C5). Fail-closed : seule une TRACE DE DÉCISION démontrée ferme ou conserve un signalement.
//  - open       : bloquant (revue). Aucun écrivain actuel ne le ferme sauf cash_payment_review (=> reviewed).
//  - recorded   : écrit seulement par resolveCashRemittance (cash_shortfall) avec decidedBy + requestId + amount => conservé,
//                 non bloquant ; toute autre forme => ambigu.
//  - reviewed   : écrit seulement par reviewCashNonPayment (cash_payment_review) avec reviewedBy/reviewedAtMs/requestId/
//                 decision/verification ; le résiduel de confirmed_unpaid reste porté par cashRemittance (évalué sur la commande).
//  - resolved   : AUCUN écrivain actuel. Accepté uniquement avec la trace du futur outil super-admin
//                 (resolvedBy, resolvedAtMs, resolutionRequestId) — voir la spécification 7E-100 §6 ; sinon ambigu.
// ── Décisions de résolution (7E-102/7E-103) ────────────────────────────────────────────────────────────────────
// Un signalement `resolved` (ou un cas client) n'est accepté que si le registre de décisions fourni par l'appelant contient
// une décision EXÉCUTÉE qui correspond exactement, avec le niveau de validation exigé. Aucun changement de statut seul ne suffit.
// Un seul super-admin existe aujourd'hui : les niveaux 2 et 3 (deux validations indépendantes) ne peuvent donc pas aboutir
// et restent bloquants tant qu'un second responsable n'a pas approuvé.
function verifyDecision(env, { decisionId, kind, subjectId, type, resolution, requestedBy, requestId, originBy, claim }) {
  const allowed = own(RESOLUTIONS, type);
  if (!allowed || !Object.prototype.hasOwnProperty.call(allowed, resolution)) return 'flag_resolution_not_allowed';
  // Niveau 3 (7E-107, C1) : INDISPONIBLE tant que le contrat de consentement du créancier n'existe pas. Aucune chaîne
  // `creditorConsentRef`, aucun registre de décisions, aucun nombre d'approbateurs ne peut fermer un dossier de niveau 3.
  if (allowed[resolution] >= 3) return 'flag_level3_unavailable';
  const d = own(env.decisions, decisionId);
  const bad = 'flag_decision_unverified';
  if (!isObject(d)) return bad;
  if (d.status !== 'executed' || d.subjectKind !== kind || d.subjectId !== subjectId || d.subjectType !== type) return bad;
  // Identifiant de requête réel (R1) : conforme, identique sur la décision et chez l'appelant, unique dans le registre.
  if (!isStr(requestId) || !REQUEST_ID_PATTERN.test(requestId) || d.requestId !== requestId) return bad;
  if (Object.entries(env.decisions).some(([id, other]) => id !== decisionId && isObject(other) && other.requestId === requestId)) return bad;
  if (d.resolution !== resolution || !isStr(requestedBy) || !ACTOR_PATTERN.test(requestedBy) || d.requestedBy !== requestedBy) return bad;
  const minTier = allowed[resolution];
  if (!isInt(d.tier) || d.tier < minTier || d.tier > 3) return bad;
  if (d.tier === 3) return 'flag_level3_unavailable';
  if (!isInt(d.remaining) || d.remaining !== 0) return bad;
  if (d.tier >= 2) {
    // Deux personnes distinctes (R3) : l'approbateur diffère du demandeur ET du décideur initial. Le demandeur PEUT être le
    // décideur initial. Identité manquante ou non conforme => en attente. Aucune normalisation tolérée.
    const approver = d.approvedBy;
    const ok = isStr(approver) && ACTOR_PATTERN.test(approver) && approver !== requestedBy && isInt(d.approvedAtMs) && isInt(d.requestedAtMs)
      && d.requestedAtMs > 0 && d.approvedAtMs >= d.requestedAtMs;
    if (!ok) return bad;
    if (originBy !== undefined && originBy !== null) {
      if (!isStr(originBy) || !ACTOR_PATTERN.test(originBy) || approver === originBy) return bad;
    } else if (ORIGIN_DECIDER_REQUIRED.includes(type)) return bad;
  }
  // Preuve vérifiée par le serveur : niveau 1 (R4) et règlements hors système (7E-107). Une chaîne fournie ne suffit jamais :
  // `evidenceRef` doit désigner un document de preuve lu côté serveur (`env.evidence`), vérifié, lié à CETTE décision, à ce
  // sujet et à cette résolution.
  const outOfSystem = OUT_OF_SYSTEM_RESOLUTIONS.includes(resolution);
  if (minTier === 1 || outOfSystem) {
    const ref = d.evidenceRef;
    if (!isStr(ref) || !ID_PATTERN.test(ref)) return bad;
    const e = own(env.evidence, ref);
    const proven = isObject(e) && e.exists === true && isObject(e.data) && e.data.status === 'verified'
      && e.data.decisionId === decisionId && e.data.subjectKind === kind && e.data.subjectId === subjectId
      && e.data.resolution === resolution && isStr(e.data.verifiedBy) && ACTOR_PATTERN.test(e.data.verifiedBy)
      && isInt(e.data.verifiedAtMs) && e.data.verifiedAtMs > 0;
    if (!proven) return bad;
    if (outOfSystem) {
      // Concordance avec la créance, calculée par le moteur depuis le signalement (jamais depuis la décision).
      const c = isObject(claim) ? claim : {};
      const matches = isInt(c.amount) && c.amount > 0 && isStr(c.beneficiaryId) && isStr(c.orderId)
        && e.data.amount === c.amount && e.data.currency === CURRENCY && e.data.beneficiaryId === c.beneficiaryId && e.data.orderId === c.orderId
        && isStr(e.data.paymentRef) && ID_PATTERN.test(e.data.paymentRef)
        && typeof e.data.contentHash === 'string' && /^[a-f0-9]{64}$/.test(e.data.contentHash) && e.data.immutable === true;
      if (!matches) return bad;
    }
  }
  return null;
}

// Signalements de rapprochement. Fail-closed : seule une décision VÉRIFIÉE ferme un signalement.
//  - open / contested : bloquant (revue).
//  - recorded (cash_shortfall) : reliquat arrêté mais PAS abandonné => bloquant tant qu'aucune décision de clôture n'existe.
//  - reviewed : écrit seulement par reviewCashNonPayment (cash_payment_review) ; conservé pour la traçabilité.
//  - resolved : aucun écrivain actuel ; accepté seulement avec les champs de trace ET une décision exécutée correspondante.
// ── Signalements L4 (L4.6) ───────────────────────────────────────────────────────────────────────────────────────
// `beneficiary_closed` (crédit omis, `parties[]`) et `beneficiary_closed_refused` (opération refusée, `beneficiary`). Le bénéficiaire
// réel est lu dans la structure imbriquée (collection + identifiant), jamais déduit d'un nom ; les champs plats éventuels
// (clientId / driverId / sellerId / pharmacieId / partnerId, ajoutés pour la requête de l'inspecteur) doivent la CONFIRMER.
// Aucune donnée personnelle n'est lue ni recopiée. Un signalement incomplet ou contradictoire est ambigu (bloquant), jamais réglable.
const L4_FLAG_TYPES = Object.freeze(['beneficiary_closed', 'beneficiary_closed_refused']);
const COLLECTION_ROLE = Object.freeze({ clients: 'client', livreurs: 'driver', sellers: 'partner', pharmacies: 'partner', restaurants: 'partner', boulangeries: 'partner' });
const FLAT_KEY_ROLE = Object.freeze({ clientId: 'client', driverId: 'driver', sellerId: 'partner', pharmacieId: 'partner', partnerId: 'partner' });
const MAX_L4_PARTIES = 10;

function l4Parties(f, label) {
  const raw = label === 'beneficiary_closed' ? f.parties : (isObject(f.beneficiary) ? [f.beneficiary] : null);
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_L4_PARTIES) return null;
  const out = [];
  for (const p of raw) {
    if (!isObject(p) || !isStr(p.collection) || !own(COLLECTION_ROLE, p.collection) || !validId(p.id)) return null;
    out.push(p);
  }
  return out;
}

function evaluateL4Flag(doc, ctx, label, mkItem) {
  const f = doc.data;
  const { role, ids } = ctx;
  const ambiguous = (reason) => [mkItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, reason)];
  const parties = l4Parties(f, label);
  if (!parties) return ambiguous('flag_parties_unreadable');
  for (const [key, role] of Object.entries(FLAT_KEY_ROLE)) {
    if (isStr(f[key]) && !parties.some((p) => own(COLLECTION_ROLE, p.collection) === role && p.id === f[key])) return ambiguous('flag_party_contradiction');
  }
  const mine = parties.find((p) => own(COLLECTION_ROLE, p.collection) === role && ids.includes(p.id));
  if (!mine) return [mkItem(TYPES.UNRELATED_DOCUMENT, STATE.AMBIGUOUS, 'flag_not_linked_to_account')];
  if (!validId(f.orderId)) return ambiguous('flag_order_missing');
  let amount = null;
  if (label === 'beneficiary_closed') {
    if (f.currency !== CURRENCY) return ambiguous('flag_currency_invalid');
    if (f.kind !== 'commission_refund_omitted') return ambiguous('flag_kind_unknown');
    if (!isInt(mine.amountWithheld) || mine.amountWithheld <= 0) return ambiguous('flag_amount_invalid');
    if (!validId(mine.sourceJournalId)) return ambiguous('flag_source_journal_missing');
    amount = mine.amountWithheld;
  } else if (f.completed === true) {
    return ambiguous('flag_completed_contradiction');
  }
  const at = (state, reason) => [mkItem(TYPES.RECONCILIATION_FLAG_OPEN, state, reason, amount)];
  if (f.status === 'open') return at(STATE.REVIEW, `flag_open:${label}`);
  // Verrou levé (clearBeneficiaryReview) : la créance reste due et bloquante. Aucune clôture sans décision + preuve de règlement.
  if (f.status === 'cleared') return at(STATE.REVIEW, 'flag_lock_lifted_debt_maintained');
  if (f.status === 'contested') return at(STATE.REVIEW, 'flag_contested');
  if (f.status === 'recorded' || f.status === 'reviewed' || f.status === 'resolved') return at(STATE.AMBIGUOUS, 'flag_closure_unproven');
  return at(STATE.AMBIGUOUS, 'unknown_flag_status');
}

function evaluateFlag(doc, ctx) {
  const { role, ids } = ctx;
  const f = doc.data;
  const base = { source: 'reconciliation_flag', refId: doc.id, orderId: isObject(f) && isStr(f.orderId) ? f.orderId : null, party: role };
  if (!isObject(f)) return [item({ ...base, type: TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'flag_not_an_object' })];
  const partyKeys = ['clientId', 'driverId', 'partnerId', 'sellerId', 'pharmacieId'];
  const present = partyKeys.filter((k) => isStr(f[k]));
  const mine = present.some((k) => ids.includes(f[k]));
  const label = flagTypeLabel(f);
  const claim = Object.prototype.hasOwnProperty.call(FLAG_CLAIM, label) ? FLAG_CLAIM[label] : null;
  const rawAmount = isInt(f.remaining) && f.remaining >= 0 ? f.remaining : f.amount ?? f.theoreticalAmount ?? f.amountDueToPartner;
  const flagItem = (type, state, reason) => item({ ...base, type, state, reason, status: f.status, amount: rawAmount, claim });
  if (typeof f.status !== 'string') return [flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, 'flag_status_unreadable')];
  if (L4_FLAG_TYPES.includes(label)) {
    return evaluateL4Flag(doc, ctx, label, (type, state, reason, amount = null) => item({ ...base, type, state, reason, status: f.status, amount, claim }));
  }
  if (!present.length) return [flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, 'flag_without_party')];
  if (!mine) return [flagItem(TYPES.UNRELATED_DOCUMENT, STATE.AMBIGUOUS, 'flag_not_linked_to_account')];
  if (f.status === 'open') return [flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.REVIEW, `flag_open:${label}`)];
  if (f.status === 'contested') return [flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.REVIEW, 'flag_contested')];
  if (f.status === 'recorded') {
    const traced = label === 'cash_shortfall' && isStr(f.decidedBy) && isStr(f.requestId) && isInt(f.amount) && f.amount >= 0;
    return [traced
      ? flagItem(TYPES.RECONCILIATION_RECORDED, STATE.REVIEW, 'flag_recorded_open')
      : flagItem(TYPES.RECONCILIATION_RECORDED, STATE.AMBIGUOUS, 'flag_recorded_unproven')];
  }
  if (f.status === 'reviewed') {
    const proven = label === 'cash_payment_review' && isStr(f.reviewedBy) && isInt(f.reviewedAtMs) && f.reviewedAtMs > 0
      && isStr(f.requestId) && isStr(f.decision) && (f.verification === 'refuted' || f.verification === 'confirmed_unpaid');
    return [proven
      ? flagItem(TYPES.RECONCILIATION_RECORDED, STATE.RETAINED, 'flag_reviewed:cash_payment_review')
      : flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, 'flag_reviewed_unproven')];
  }
  if (f.status === 'resolved') {
    const traced = isStr(f.resolvedBy) && isInt(f.resolvedAtMs) && f.resolvedAtMs > 0 && isStr(f.resolutionRequestId)
      && isStr(f.resolutionDecisionId) && isStr(f.resolution);
    if (!traced) return [flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, 'flag_resolved_unproven')];
    const problem = verifyDecision(ctx, {
      decisionId: f.resolutionDecisionId, kind: 'flag', subjectId: doc.id, type: label, resolution: f.resolution,
      requestedBy: f.resolvedBy, requestId: f.resolutionRequestId, originBy: f.decidedBy,
      claim: { orderId: f.orderId, amount: f.amount, beneficiaryId: label === 'partner_credit_missing' ? f.sellerId : label === 'driver_advance_unreimbursed' ? f.driverId : undefined },
    });
    return [problem
      ? flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, problem)
      : flagItem(TYPES.RECONCILIATION_RECORDED, STATE.RETAINED, `flag_resolved:${label}`)];
  }
  return [flagItem(TYPES.RECONCILIATION_FLAG_OPEN, STATE.AMBIGUOUS, 'unknown_flag_status')];
}

// Cas « non-paiement espèces confirmé » d'un CLIENT : traité au cas par cas, aucune dette n'est inventée (montant null).
// Il bloque tant qu'une décision exécutée de type `client_cash_nonpayment` ne le ferme pas.
function clientCashCaseClosed(env, orderId, order) {
  const review = isObject(order.cashPayment) && isObject(order.cashPayment.review) ? order.cashPayment.review : null;
  const candidates = Object.entries(env.decisions)
    .filter(([, d]) => isObject(d) && d.subjectKind === 'order' && d.subjectId === orderId && d.subjectType === 'client_cash_nonpayment')
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return candidates.some(([id, d]) => verifyDecision(env, {
    decisionId: id, kind: 'order', subjectId: orderId, type: 'client_cash_nonpayment', resolution: d.resolution,
    requestedBy: d.requestedBy, requestId: d.requestId, originBy: review ? review.byUid : undefined,
  }) === null);
}

const compareItems = (a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1
  : (a.refId || '') < (b.refId || '') ? -1 : (a.refId || '') > (b.refId || '') ? 1
    : a.reason < b.reason ? -1 : a.reason > b.reason ? 1
      : a.state < b.state ? -1 : a.state > b.state ? 1
        : (a.source || '') < (b.source || '') ? -1 : (a.source || '') > (b.source || '') ? 1
          : (a.orderId || '') < (b.orderId || '') ? -1 : (a.orderId || '') > (b.orderId || '') ? 1
            : (a.amount ?? -1) - (b.amount ?? -1));

// Comptes distincts (D-6) : `orders` = commandes concernées, `economic` = créances économiques (clé orderId|créance ; un
// élément sans clé fiable compte séparément), `flags` = signalements bloquants. Ne dépend d'aucune déduplication.
function summarize(sortedObligations, sortedRetained, sortedManual = []) {
  const byType = {};
  for (const i of sortedObligations) byType[i.type] = (byType[i.type] || 0) + 1;
  const ambiguous = sortedObligations.filter((i) => i.state === STATE.AMBIGUOUS).length;
  const orderIds = new Set();
  const keys = new Set();
  let unkeyed = 0;
  let flagCount = 0;
  for (const i of sortedObligations) {
    if (isStr(i.orderId) && !i.orderId.startsWith('invalid:') && ID_PATTERN.test(i.orderId)) orderIds.add(i.orderId);
    if (i.economicKey) keys.add(i.economicKey); else unkeyed += 1;
    if (i.source === 'reconciliation_flag') flagCount += 1;
  }
  return {
    blocking: sortedObligations.length > 0,
    code: sortedObligations.length === 0 ? CODE.NONE : ambiguous > 0 ? CODE.AMBIGUOUS : CODE.PENDING,
    summary: {
      open: sortedObligations.filter((i) => i.state === STATE.OPEN).length,
      review: sortedObligations.filter((i) => i.state === STATE.REVIEW).length,
      ambiguous,
      retained: sortedRetained.length,
      manualReview: sortedManual.length,
      orders: orderIds.size,
      economic: keys.size + unkeyed,
      flags: flagCount,
      byType,
    },
  };
}

const isTruncationItem = (i) => i.type === TYPES.INPUT_INCOMPLETE && typeof i.reason === 'string' && i.reason.endsWith('_truncated');

function emptyResult(items) {
  const sorted = [...items].sort(compareItems);
  const obligations = sorted.filter((i) => i.blocking);
  const retained = sorted.filter((i) => i.state === STATE.RETAINED);
  const manualReview = sorted.filter((i) => i.state === STATE.MANUAL_REVIEW);
  const s = summarize(obligations, retained, manualReview);
  return {
    version: VERSION, blocking: s.blocking, code: s.code, manualReviewRequired: obligations.some(isTruncationItem),
    obligations, retained, manualReview, summary: s.summary,
  };
}

const failClosed = (type, reason, role) => emptyResult([item({ type, state: STATE.AMBIGUOUS, reason, source: 'input', party: role || 'unknown' })]);

// C6 : l'appelant fournit SON ensemble de statuts terminaux (voir INSPECTOR_TERMINAL_STATUSES). Tableau non vide, sans
// doublon, composé uniquement de statuts terminaux connus. Tout le reste => null => blocage global.
function parseTerminalStatuses(v) {
  if (!Array.isArray(v) || v.length === 0 || v.length > KNOWN_TERMINAL_STATUSES.length) return null;
  const set = new Set();
  for (const s of v) {
    if (typeof s !== 'string' || !KNOWN_TERMINAL_STATUSES.includes(s) || set.has(s)) return null;
    set.add(s);
  }
  return set;
}

// ── Contrat de lecture (D-1, D-2) ────────────────────────────────────────────────────────────────────────────────
// Requêtes OBLIGATOIRES par rôle et par liste (miroir des requêtes réelles des inspecteurs). Pour chaque couple
// (clé, identifiant du compte) l'appelant doit fournir { key, id, limit, size }. Un couple manquant, inconnu, dupliqué ou
// mal formé, une limite hors 1..READ_LIMIT, une taille incohérente => ambigu. Une requête qui atteint sa limite => lecture
// potentiellement tronquée => revue manuelle. Aucune pagination n'est faite à l'intérieur d'une transaction.
function requiredKeys(name, role, kind) {
  if (name === 'orders') return role === 'client' ? ['clientId'] : role === 'driver' ? ['driverId'] : ['sellerId', ...(kind ? [kind] : [])];
  if (name === 'settlements') return role === 'client' ? ['clientId'] : role === 'driver' ? ['driverIds', 'holderDriverId'] : [];
  return role === 'client' ? ['clientId'] : role === 'driver' ? ['driverId'] : ['partnerId', 'sellerId', 'pharmacieId'];
}

function requiredQueries(roleRaw, idsRaw) {
  const role = normalizeRole(roleRaw);
  const ids = Array.isArray(idsRaw) ? [...new Set(idsRaw.filter(isStr))] : [];
  if (!role || !ids.length) return null;
  const kind = partnerKind(roleRaw);
  const out = {};
  for (const name of LISTS) out[name] = requiredKeys(name, role, kind).flatMap((key) => ids.map((id) => ({ key, id })));
  return out;
}

function coverage(name, list, reads, role, kind, ids) {
  if (!isObject(reads)) return { problems: ['reads_missing'], truncated: false };
  const entry = reads[name];
  if (!isObject(entry) || !Array.isArray(entry.queries) || Object.keys(entry).some((k) => k !== 'queries')) {
    return { problems: [`${name}_coverage_unproven`], truncated: false };
  }
  const required = requiredKeys(name, role, kind);
  const problems = new Set();
  const seen = new Set();
  let sum = 0;
  let max = 0;
  let truncated = false;
  for (const q of entry.queries) {
    const shapeOk = isObject(q) && Object.keys(q).length === 4 && ['key', 'id', 'limit', 'size'].every((k) => Object.prototype.hasOwnProperty.call(q, k));
    const valid = shapeOk && isStr(q.key) && isStr(q.id) && q.limit === READ_LIMIT
      && isInt(q.size) && q.size >= 0 && q.size <= q.limit && required.includes(q.key) && ids.includes(q.id);
    if (!valid) { problems.add(`${name}_query_invalid`); continue; }
    const k = `${q.key}|${q.id}`;
    if (seen.has(k)) { problems.add(`${name}_query_duplicate`); continue; }
    seen.add(k);
    if (q.size >= q.limit) truncated = true;
    sum += q.size;
    max = Math.max(max, q.size);
  }
  if (!required.every((key) => ids.every((id) => seen.has(`${key}|${id}`)))) problems.add(`${name}_queries_incomplete`);
  // Union dédupliquée des documents : entre la plus grande requête et la somme des requêtes.
  if (list.length > sum || list.length < max) problems.add(`${name}_read_size_mismatch`);
  if (truncated) problems.add(`${name}_truncated`);
  return { problems: [...problems], truncated };
}

// Identifiants des journaux de débit à fournir pour les commandes wallet v2 d'un CLIENT (lectures ponctuelles, sans plafond).
function requiredWalletDebitIds(roleRaw, orders) {
  if (normalizeRole(roleRaw) !== 'client' || !Array.isArray(orders)) return [];
  const ids = [];
  for (const d of orders) {
    if (isObject(d) && isStr(d.id) && isObject(d.data) && needsDebitProof(d.data)) ids.push(`order_${d.id}`);
  }
  return ids.sort();
}

// entrée : {
//   role, ids, terminalStatuses (obligatoire), orders, settlements, flags : voir 7E-98/7E-100
//   reads:        { orders: {queries:[{key,id,limit,size}]}, settlements: {...}, flags: {...} }   (preuve de couverture)
//   walletDebits: [{ id:'order_<orderId>', exists:boolean, data }]   client : débit wallet de chaque commande v2 wallet livrée
//   decisions:    [{ id, data }]   registre de décisions exécutées (nécessaire aux signalements `resolved` et aux cas clients)
//   evidence:     [{ id, exists, data }]   preuves lues côté serveur (niveau 1 et règlements hors système), liées à une décision
//   résultat :    { ..., obligations (bloquantes), retained (décisions conservées), manualReview (paiements wallet historiques non
//                 prouvables : NI dette NI règlement, non bloquant), summary }
// }
function evaluateAccountObligations(input) {
  try {
    if (!isObject(input)) return failClosed(TYPES.INVALID_INPUT, 'input_not_an_object');
    const role = normalizeRole(input.role);
    if (!role) return failClosed(TYPES.INVALID_INPUT, 'unknown_role');
    const ids = Array.isArray(input.ids) ? [...new Set(input.ids.filter(isStr))] : [];
    if (!ids.length) return failClosed(TYPES.INVALID_INPUT, 'account_ids_missing', role);
    const terminal = parseTerminalStatuses(input.terminalStatuses);
    if (!terminal) return failClosed(TYPES.INVALID_INPUT, 'terminal_statuses_invalid', role);
    const kind = partnerKind(input.role);
    const items = [];
    const bad = (type, reason, extra = {}) => items.push(item({ type, state: STATE.AMBIGUOUS, reason, source: 'input', party: role, ...extra }));
    if (input.legacyAbsentIsPaid !== undefined) bad(TYPES.INVALID_INPUT, 'legacy_option_unsupported');
    if (input.truncated !== undefined && !(isObject(input.truncated) && Object.values(input.truncated).every((v) => v === false))) {
      bad(TYPES.INPUT_INCOMPLETE, 'truncated_flag_invalid_or_set');
    }
    if (isObject(input.reads) && Object.keys(input.reads).some((k) => !LISTS.includes(k))) bad(TYPES.INVALID_INPUT, 'reads_unknown_key');

    const debits = Object.create(null);
    if (input.walletDebits !== undefined) {
      if (!Array.isArray(input.walletDebits)) bad(TYPES.INVALID_INPUT, 'wallet_debits_invalid');
      else {
        for (const e of input.walletDebits) {
          if (!isObject(e) || !isStr(e.id) || typeof e.exists !== 'boolean' || (e.exists && !isObject(e.data)) || own(debits, e.id) !== undefined) bad(TYPES.INVALID_INPUT, 'wallet_debits_invalid');
          else debits[e.id] = { exists: e.exists, data: e.data };
        }
      }
    }
    const decisions = Object.create(null);
    if (input.decisions !== undefined) {
      if (!Array.isArray(input.decisions)) bad(TYPES.INVALID_INPUT, 'decisions_invalid');
      else {
        for (const e of input.decisions) {
          if (!isObject(e) || !isStr(e.id) || !isObject(e.data) || own(decisions, e.id) !== undefined) bad(TYPES.INVALID_INPUT, 'decisions_invalid');
          else decisions[e.id] = e.data;
        }
      }
    }
    const evidence = Object.create(null);
    if (input.evidence !== undefined) {
      if (!Array.isArray(input.evidence)) bad(TYPES.INVALID_INPUT, 'evidence_invalid');
      else {
        for (const e of input.evidence) {
          if (!isObject(e) || !isStr(e.id) || typeof e.exists !== 'boolean' || (e.exists && !isObject(e.data)) || own(evidence, e.id) !== undefined) bad(TYPES.INVALID_INPUT, 'evidence_invalid');
          else evidence[e.id] = { exists: e.exists, data: e.data };
        }
      }
    }
    const ctx = { role, ids, terminal, debits, decisions, evidence };
    const lists = [
      ['orders', evaluateOrder, true],
      ['settlements', evaluateSettlement, role === 'client' || role === 'driver'],
      ['flags', evaluateFlag, true],
    ];
    for (const [name, evaluate, required] of lists) {
      const list = input[name];
      if (list === undefined || list === null) {
        if (required) bad(TYPES.INPUT_INCOMPLETE, `${name}_not_provided`);
        continue;
      }
      if (!Array.isArray(list)) {
        bad(TYPES.INVALID_INPUT, `${name}_not_an_array`);
        continue;
      }
      const cov = coverage(name, list, input.reads, role, kind, ids);
      for (const problem of cov.problems) bad(problem.endsWith('_truncated') ? TYPES.INPUT_INCOMPLETE : problem === 'reads_missing' || problem.endsWith('_unproven') || problem.endsWith('_incomplete') ? TYPES.INPUT_INCOMPLETE : TYPES.INVALID_INPUT, problem);
      const seen = new Set();
      for (const doc of list) {
        try {
          if (!isObject(doc) || !isStr(doc.id)) {
            bad(TYPES.EVALUATION_ERROR, `${name}_entry_without_id`);
          } else if (seen.has(doc.id)) {
            // Même document fourni deux fois : défaut d'appel, évalué une seule fois, jamais compté deux fois.
            bad(TYPES.EVALUATION_ERROR, `${name}_duplicate_document_id`, { refId: doc.id });
          } else {
            seen.add(doc.id);
            // Identifiant non fiable : aucune clé économique ; l'élément reste distinct (empreinte) et le résultat bloque.
            if (!ID_PATTERN.test(doc.id)) bad(TYPES.EVALUATION_ERROR, `${name}_invalid_document_id`, { refId: doc.id });
            items.push(...evaluate(doc, ctx));
          }
        } catch (_) {
          bad(TYPES.EVALUATION_ERROR, `${name}_entry_evaluation_failed`, { refId: isObject(doc) ? doc.id : null });
        }
      }
    }
    return emptyResult(items);
  } catch (_) {
    return failClosed(TYPES.EVALUATION_ERROR, 'unexpected_failure');
  }
}

// Remet un élément d'un résultat (potentiellement altéré) sous forme canonique et sûre : toute valeur hors liste blanche
// est neutralisée, jamais recopiée. La clé économique est RECALCULÉE (jamais reprise). `retainedSlot` : l'élément provient de
// `retained`; il n'y reste que s'il est réellement « retained » du bon type, sinon il devient une obligation ambiguë.
function normalizeSnapshotItem(i, slot) {
  if (!isObject(i)) return item({ type: TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'item_invalid', source: 'input' });
  const validState = STATE_VALUES.has(i.state) && TYPE_VALUES.has(i.type);
  const ok = validState && (slot === 'retained'
    ? i.state === STATE.RETAINED && i.type === TYPES.RECONCILIATION_RECORDED
    : slot === 'manualReview'
      ? i.state === STATE.MANUAL_REVIEW && i.type === TYPES.LEGACY_WALLET_UNPROVEN
      : i.state !== STATE.RETAINED && i.state !== STATE.MANUAL_REVIEW);
  if (!ok) {
    return item({ type: validState ? i.type : TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'item_invalid', source: i.source, refId: i.refId, orderId: i.orderId, party: i.party });
  }
  return item({ ...i, claim: CLAIMS.includes(i.claim) ? i.claim : null });
}

// Déduplication des seuls éléments STRICTEMENT identiques (affichage) : les comptes ne passent jamais par elle.
function dedupe(sortedItems) {
  const seen = new Set();
  return sortedItems.filter((i) => {
    const key = JSON.stringify(i);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// Contenu proposé pour `account_deletions/{uid}.financialSnapshot` (NON écrit par ce module). Ne lève jamais, ne fait pas
// confiance à `blocking`/`code`/`summary`/`manualReviewRequired` du résultat : tout est recalculé depuis les éléments normalisés.
// Un résultat illisible, incohérent ou altéré produit un snapshot BLOQUANT. `atMs` est fourni par l'appelant (aucune horloge).
function buildFinancialSnapshot(result, options) {
  const atMs = isObject(options) && isInt(options.atMs) ? options.atMs : null;
  let obligations = [];
  let retained = [];
  let manualReview = [];
  let inconsistent = false;
  let unreadable = false;
  try {
    if (!isObject(result) || !Array.isArray(result.obligations) || !Array.isArray(result.retained)) {
      unreadable = true;
    } else {
      if (result.manualReview !== undefined && !Array.isArray(result.manualReview)) throw new Error('manualReview');
      obligations = result.obligations.map((i) => normalizeSnapshotItem(i, 'obligations'));
      retained = result.retained.map((i) => normalizeSnapshotItem(i, 'retained'));
      manualReview = (result.manualReview || []).map((i) => normalizeSnapshotItem(i, 'manualReview'));
      // Un élément invalide d'un emplacement non bloquant est devenu bloquant : il bascule côté obligations.
      const moved = [...retained, ...manualReview].filter((i) => i.blocking);
      retained = retained.filter((i) => !i.blocking);
      manualReview = manualReview.filter((i) => !i.blocking);
      obligations = obligations.concat(moved);
      const raw = summarize([...obligations].sort(compareItems), [...retained].sort(compareItems), [...manualReview].sort(compareItems));
      const sum = result.summary;
      const sumOk = isObject(sum) && ['open', 'review', 'ambiguous', 'retained', 'manualReview', 'orders', 'economic', 'flags'].every((k) => sum[k] === raw.summary[k]);
      if (!sumOk || result.blocking !== raw.blocking || result.code !== raw.code) inconsistent = true;
    }
  } catch (_) {
    unreadable = true;
    obligations = [];
    retained = [];
    manualReview = [];
  }
  if (unreadable) obligations.push(item({ type: TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'result_unreadable', source: 'input' }));
  else if (inconsistent) obligations.push(item({ type: TYPES.EVALUATION_ERROR, state: STATE.AMBIGUOUS, reason: 'result_inconsistent', source: 'input' }));
  const sortedObligations = [...obligations].sort(compareItems);
  const sortedRetained = [...retained].sort(compareItems);
  const sortedManual = [...manualReview].sort(compareItems);
  const s = summarize(sortedObligations, sortedRetained, sortedManual);
  const all = [...dedupe(sortedObligations), ...dedupe(sortedRetained), ...dedupe(sortedManual)];
  const shown = all.slice(0, MAX_SNAPSHOT_ITEMS);
  return {
    version: VERSION,
    atMs,
    blocking: s.blocking,
    code: s.code,
    manualReviewRequired: sortedObligations.some(isTruncationItem),
    currency: CURRENCY,
    counts: {
      open: s.summary.open, review: s.summary.review, ambiguous: s.summary.ambiguous, retained: s.summary.retained,
      manualReview: s.summary.manualReview, orders: s.summary.orders, economic: s.summary.economic, flags: s.summary.flags,
    },
    items: shown.map((i) => ({
      type: i.type, state: i.state, source: i.source, refId: i.refId, orderId: i.orderId, party: i.party,
      amount: i.amount, currency: i.currency, status: i.status, reason: i.reason, claim: i.claim, economicKey: i.economicKey,
    })),
    truncated: all.length > shown.length,
    omitted: all.length - shown.length,
  };
}

// ── Retraits (L2.1) ──────────────────────────────────────────────────────────────────────────────────────────────
// Les inspecteurs historiques traitent `withdrawal_requests` avec l'ensemble de statuts des COMMANDES : `sent` (payout confirmé)
// et `processed` (règlement manuel) n'y figurent pas, d'où un refus de suppression à tort. Ce prédicat pur classe un retrait d'après
// les écritures réelles, vérifiées dans le code d'écriture (jamais d'après le seul libellé du statut) :
//   processing       initiateWithdrawal (index.js) : solde débité, payout pas encore accusé               -> OUVERT
//   provider_pending référence obtenue, état non final (applyPayoutStatus, checkWithdrawalStatus)        -> OUVERT
//   pending_manual   issue ambiguë, mismatch référence/montant, suivi épuisé (needsReview)                -> OUVERT
//   sent             applyPayoutStatus SUCCESSFUL : settlementConfirmed:true, needsReview:false            -> CLOS si confirmé
//   processed        adminApproveWithdrawalCF : settlementConfirmed:true + processedBy                     -> CLOS si confirmé
//   failed_refunded  compensation unique : compensated:true, settlementConfirmed:false, wallet recrédité   -> CLOS si compensé
// Tout autre statut (dont l'ancien `pending`, que le serveur n'écrit plus), tout drapeau contradictoire, `needsReview`, `anomaly`,
// montant invalide ou rattachement incertain => AMBIGU et bloquant. Limite reconnue : un administrateur peut modifier ces champs
// (règles Firestore : update admin) ; le prédicat ne peut pas distinguer un faux « clos » écrit à la main.
const WITHDRAWAL_STATUS = Object.freeze({
  OPEN: Object.freeze(['processing', 'provider_pending', 'pending_manual']),
  SETTLED: Object.freeze(['sent', 'processed']),
  REFUNDED: Object.freeze(['failed_refunded']),
});
const WITHDRAWAL_STATE = Object.freeze({ CLOSED: 'closed', OPEN: 'open', AMBIGUOUS: 'ambiguous' });
const WITHDRAWAL_REASONS = Object.freeze([
  'withdrawal_processing', 'withdrawal_provider_pending', 'withdrawal_pending_manual',
  'withdrawal_settled', 'withdrawal_settled_manually', 'withdrawal_refunded',
  'withdrawal_not_an_object', 'withdrawal_not_linked_to_account', 'withdrawal_status_unreadable', 'withdrawal_status_unknown',
  'withdrawal_amount_invalid', 'withdrawal_flag_invalid', 'withdrawal_needs_review', 'withdrawal_anomaly', 'withdrawal_flags_contradictory',
  'withdrawal_settlement_unconfirmed', 'withdrawal_refund_unconfirmed',
  'withdrawals_not_provided', 'withdrawals_not_an_array', 'withdrawals_coverage_unproven', 'withdrawals_queries_incomplete',
  'withdrawals_query_invalid', 'withdrawals_query_duplicate', 'withdrawals_read_size_mismatch', 'withdrawals_truncated',
  'withdrawals_entry_without_id', 'withdrawals_duplicate_document_id', 'withdrawals_account_ids_missing', 'withdrawals_unexpected_failure',
]);

function classifyWithdrawal(w, accountIds) {
  const ambiguous = (reason) => ({ state: WITHDRAWAL_STATE.AMBIGUOUS, reason });
  if (!isObject(w)) return ambiguous('withdrawal_not_an_object');
  if (!isStr(w.userId) || !Array.isArray(accountIds) || !accountIds.includes(w.userId)) return ambiguous('withdrawal_not_linked_to_account');
  if (typeof w.status !== 'string') return ambiguous('withdrawal_status_unreadable');
  if (!isInt(w.amount) || w.amount <= 0) return ambiguous('withdrawal_amount_invalid');
  for (const flag of ['needsReview', 'compensated', 'settlementConfirmed']) {
    if (has(w, flag) && typeof w[flag] !== 'boolean') return ambiguous('withdrawal_flag_invalid');
  }
  // Un état non final reste ouvert quoi qu'il porte d'autre : l'argent est débité sans issue connue.
  if (WITHDRAWAL_STATUS.OPEN.includes(w.status)) return { state: WITHDRAWAL_STATE.OPEN, reason: `withdrawal_${w.status}` };
  const known = WITHDRAWAL_STATUS.SETTLED.includes(w.status) || WITHDRAWAL_STATUS.REFUNDED.includes(w.status);
  if (!known) return ambiguous('withdrawal_status_unknown');
  if (w.needsReview === true) return ambiguous('withdrawal_needs_review');
  if (has(w, 'anomaly')) return ambiguous('withdrawal_anomaly');
  if (w.compensated === true && w.settlementConfirmed === true) return ambiguous('withdrawal_flags_contradictory');
  if (w.status === 'sent') {
    return w.settlementConfirmed === true && w.compensated !== true
      ? { state: WITHDRAWAL_STATE.CLOSED, reason: 'withdrawal_settled' } : ambiguous('withdrawal_settlement_unconfirmed');
  }
  if (w.status === 'processed') {
    return w.settlementConfirmed === true && w.compensated !== true && isStr(w.processedBy)
      ? { state: WITHDRAWAL_STATE.CLOSED, reason: 'withdrawal_settled_manually' } : ambiguous('withdrawal_settlement_unconfirmed');
  }
  return w.compensated === true && w.settlementConfirmed !== true
    ? { state: WITHDRAWAL_STATE.CLOSED, reason: 'withdrawal_refunded' } : ambiguous('withdrawal_refund_unconfirmed');
}

// entrée : { ids:[userId...], withdrawals:[{id,data}], reads:{queries:[{key:'userId',id,limit:201,size}]} }
// Même discipline que les autres listes : preuve de couverture exigée, 201 résultats = tronqué, doublon = défaut d'appel.
function evaluateWithdrawals(input) {
  const out = (obligations, problems) => {
    const items = [...obligations, ...problems.map((reason) => ({ refId: null, state: 'ambiguous', reason, amount: null }))];
    const open = items.filter((i) => i.state === WITHDRAWAL_STATE.OPEN).length;
    const amb = items.filter((i) => i.state === WITHDRAWAL_STATE.AMBIGUOUS).length;
    return {
      blocking: open + amb > 0,
      code: amb > 0 ? CODE.AMBIGUOUS : open > 0 ? CODE.PENDING : CODE.NONE,
      obligations: items.filter((i) => i.state !== WITHDRAWAL_STATE.CLOSED),
      summary: { open, ambiguous: amb, closed: items.filter((i) => i.state === WITHDRAWAL_STATE.CLOSED).length },
    };
  };
  try {
    if (!isObject(input)) return out([], ['withdrawals_unexpected_failure']);
    const ids = Array.isArray(input.ids) ? [...new Set(input.ids.filter(isStr))] : [];
    if (!ids.length) return out([], ['withdrawals_account_ids_missing']);
    const problems = new Set();
    const list = input.withdrawals;
    if (list === undefined || list === null) return out([], ['withdrawals_not_provided']);
    if (!Array.isArray(list)) return out([], ['withdrawals_not_an_array']);
    const queries = isObject(input.reads) ? input.reads.queries : undefined;
    if (!Array.isArray(queries)) problems.add('withdrawals_coverage_unproven');
    else {
      const seen = new Set();
      let sum = 0;
      let max = 0;
      for (const q of queries) {
        const valid = isObject(q) && Object.keys(q).length === 4 && ['key', 'id', 'limit', 'size'].every((k) => Object.prototype.hasOwnProperty.call(q, k))
          && q.key === 'userId' && isStr(q.id) && ids.includes(q.id) && q.limit === READ_LIMIT && isInt(q.size) && q.size >= 0 && q.size <= q.limit;
        if (!valid) { problems.add('withdrawals_query_invalid'); continue; }
        if (seen.has(q.id)) { problems.add('withdrawals_query_duplicate'); continue; }
        seen.add(q.id);
        if (q.size >= q.limit) problems.add('withdrawals_truncated');
        sum += q.size;
        max = Math.max(max, q.size);
      }
      if (!ids.every((id) => seen.has(id))) problems.add('withdrawals_queries_incomplete');
      if (list.length > sum || list.length < max) problems.add('withdrawals_read_size_mismatch');
    }
    const obligations = [];
    const seenDocs = new Set();
    for (const doc of list) {
      if (!isObject(doc) || !isStr(doc.id)) { problems.add('withdrawals_entry_without_id'); continue; }
      if (seenDocs.has(doc.id)) { problems.add('withdrawals_duplicate_document_id'); continue; }
      seenDocs.add(doc.id);
      const verdict = classifyWithdrawal(doc.data, ids);
      obligations.push({ refId: safeId(doc.id), state: verdict.state, reason: verdict.reason, amount: isObject(doc.data) ? amountOrNull(doc.data.amount) : null });
    }
    return out(obligations, [...problems]);
  } catch (_) {
    return out([], ['withdrawals_unexpected_failure']);
  }
}

module.exports = {
  evaluateAccountObligations,
  evaluateWithdrawals,
  classifyWithdrawal,
  WITHDRAWAL_STATUS,
  WITHDRAWAL_STATE,
  WITHDRAWAL_REASONS,
  buildFinancialSnapshot,
  requiredQueries,
  requiredWalletDebitIds,
  normalizeRole,
  TYPES,
  STATE,
  CODE,
  ACTIVE_STATUSES,
  KNOWN_TERMINAL_STATUSES,
  INSPECTOR_TERMINAL_STATUSES,
  FLAG_TYPES,
  RESOLUTIONS,
  UNAUTHORIZED_RESOLUTIONS,
  OUT_OF_SYSTEM_RESOLUTIONS,
  walletGeneration,
  READ_LIMIT,
  MAX_SNAPSHOT_ITEMS,
};
