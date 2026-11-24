'use strict';

// Mission 7D-5 — état du PAIEMENT en espèces d'une commande Restaurant/Boulangerie v2 (logique pure, testable sans Firestore).
//
// Pourquoi un champ dédié : `isPaid:false` ne prouve rien (le livreur a pu déclarer « Non payé », ne rien déclarer, ou
// l'application a pu être ancienne). `orders.cashPayment` (écrit UNIQUEMENT par le serveur) conserve la déclaration du
// livreur, son auteur, sa date, l'état de vérification et l'historique. Il ne modifie ni `cashRemittance` ni aucun montant :
// le dû au partenaire (productAmount) reste intact, une déclaration ne le supprime jamais ; seule la décision du
// super-administrateur (resolveCashRemittance) peut arrêter un montant final. Aucun mouvement de wallet ici.
//
//   status       : 'confirmed'            le livreur déclare avoir encaissé (déclaration, pas une preuve)
//                  'non_payment_declared' le livreur déclare que le client n'a pas payé
//                  'unknown'              rien n'a été déclaré (ancienne application, commande antérieure à 7D-5)
//   verification : 'not_required' | 'pending_review' | 'confirmed_unpaid' | 'refuted'
//
// Les commandes historiques (sans amountsVersion 2) n'ont jamais de cashPayment.

const STATUS = Object.freeze({ CONFIRMED: 'confirmed', NON_PAYMENT: 'non_payment_declared', UNKNOWN: 'unknown' });
const VERIFICATION = Object.freeze({
  NOT_REQUIRED: 'not_required', PENDING: 'pending_review', CONFIRMED_UNPAID: 'confirmed_unpaid', REFUTED: 'refuted',
});
const REVIEW_DECISIONS = Object.freeze(['confirm_unpaid', 'refute']);
const HISTORY_LIMIT = 20;

class PaymentRefusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

const pushHistory = (history, entry) => [...(Array.isArray(history) ? history : []), entry].slice(-HISTORY_LIMIT);

// État posé par deliverOrderCF. Seul un booléen EXPLICITE vaut déclaration ; absent ou autre type = inconnu.
function initialCashPayment({ markCashPaid, totalAmount, uid, nowMs }) {
  const common = { theoreticalTotal: totalAmount, basis: 'driver_declaration' };
  if (markCashPaid === true) {
    return {
      ...common, status: STATUS.CONFIRMED, verification: VERIFICATION.NOT_REQUIRED, declaredBy: uid, declaredAtMs: nowMs,
      source: 'delivery', history: [{ atMs: nowMs, byUid: uid, byRole: 'driver', event: 'delivery_paid_declared' }],
    };
  }
  if (markCashPaid === false) {
    return {
      ...common, status: STATUS.NON_PAYMENT, verification: VERIFICATION.PENDING, declaredBy: uid, declaredAtMs: nowMs,
      source: 'delivery', history: [{ atMs: nowMs, byUid: uid, byRole: 'driver', event: 'delivery_non_payment_declared' }],
    };
  }
  return {
    ...common, status: STATUS.UNKNOWN, verification: VERIFICATION.NOT_REQUIRED, declaredBy: null, declaredAtMs: null,
    source: 'delivery', history: [{ atMs: nowMs, byUid: uid, byRole: 'driver', event: 'delivery_payment_unspecified' }],
  };
}

// Déclaration tardive du livreur final. Commande sans cashPayment (antérieure à 7D-5) = inconnu.
// Retourne { replay: true } (déjà déclaré) ou { next } (nouvel état).
function declareNonPayment(current, { uid, nowMs, reason, totalAmount }) {
  const text = typeof reason === 'string' ? reason.trim() : '';
  const status = current && current.status ? current.status : STATUS.UNKNOWN;
  if (status === STATUS.NON_PAYMENT) return { replay: true };
  if (status === STATUS.CONFIRMED) {
    throw new PaymentRefusal('PAYMENT_ALREADY_DECLARED_PAID',
      'Vous avez déclaré le paiement reçu à la livraison : en cas de désaccord, utilisez la contestation du reversement');
  }
  if (text.length < 10 || text.length > 300) throw new PaymentRefusal('REASON_REQUIRED', 'Motif requis (10 à 300 caractères)');
  const base = current && typeof current === 'object' ? current : { theoreticalTotal: totalAmount, basis: 'driver_declaration', source: 'later_report' };
  return {
    next: {
      ...base, status: STATUS.NON_PAYMENT, verification: VERIFICATION.PENDING, declaredBy: uid, declaredAtMs: nowMs, reason: text,
      history: pushHistory(base.history, { atMs: nowMs, byUid: uid, byRole: 'driver', event: 'non_payment_declared', reason: text }),
    },
  };
}

// Examen par le super-administrateur : confirme ou infirme le non-paiement. Aucune conséquence financière automatique.
function reviewNonPayment(current, { uid, nowMs, requestId, decision, justification }) {
  if (typeof requestId !== 'string' || requestId.length < 16 || requestId.length > 128) {
    throw new PaymentRefusal('REQUEST_ID_REQUIRED', 'requestId idempotent requis');
  }
  if (!current || current.status !== STATUS.NON_PAYMENT) {
    throw new PaymentRefusal('NO_NON_PAYMENT_DECLARED', 'Aucun non-paiement déclaré sur cette commande');
  }
  if (current.review && current.review.requestId === requestId) return { replay: true };
  if (current.verification !== VERIFICATION.PENDING) {
    throw new PaymentRefusal('PAYMENT_ALREADY_REVIEWED', 'Ce non-paiement a déjà été examiné');
  }
  if (!REVIEW_DECISIONS.includes(decision)) throw new PaymentRefusal('INVALID_DECISION', 'Décision invalide');
  const text = typeof justification === 'string' ? justification.trim() : '';
  if (text.length < 10 || text.length > 500) throw new PaymentRefusal('JUSTIFICATION_REQUIRED', 'Justification requise (10 à 500 caractères)');
  const verification = decision === 'confirm_unpaid' ? VERIFICATION.CONFIRMED_UNPAID : VERIFICATION.REFUTED;
  return {
    next: {
      ...current, verification,
      review: { requestId, decision, byUid: uid, atMs: nowMs, justification: text },
      history: pushHistory(current.history, { atMs: nowMs, byUid: uid, byRole: 'admin', event: `review_${decision}`, justification: text }),
    },
  };
}

module.exports = {
  STATUS, VERIFICATION, REVIEW_DECISIONS, PaymentRefusal, initialCashPayment, declareNonPayment, reviewNonPayment,
};
