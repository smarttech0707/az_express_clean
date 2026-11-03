'use strict';

// Rapprochement MANUEL des commandes E-Kbine historiques (créées avant `ekCreateOrderCF`).
//
// Fonction PURE : elle classe des documents déjà lus, elle n'écrit rien, ne touche aucun solde et ne crée aucun
// remboursement. Une commande « sans preuve serveur » n'a ni `walletDebited` ni `debitedAmount` : son débit côté
// client a été écrit par l'application dans `wallet_transactions` (niveau supérieur, `{uid, type:'ekbine_payment',
// amount:-montant, createdAt}`), sans lien avec la commande et falsifiable. Un candidat de débit est donc un INDICE,
// jamais une preuve : la décision finale revient à un humain (relevé de l'opérateur, solde du client).

const WINDOW_MS = 15 * 60 * 1000; // le débit client précède la création de la commande de quelques secondes

const toMs = (t) => (t && typeof t.toMillis === 'function' ? t.toMillis() : (typeof t === 'number' ? t : null));

// Commande déjà traitée par le serveur : hors périmètre (aucun risque de double traitement).
function isServerProcessed(order) {
  return order.walletDebited !== undefined || order.debitedAmount !== undefined
    || order.refunded !== undefined || order.agentCredited !== undefined;
}

/**
 * @param {Array<{id:string, ...order}>} orders      commandes ekbine_orders
 * @param {Array<{id:string, uid:string, amount:number, createdAt:any}>} debits  wallet_transactions type ekbine_payment
 * @param {Set<string>|string[]} creditedOrderIds     orderId présents dans audit_logs action 'ekbine_confirm_order'
 * @param {Array<{orderId:string}>} refundLedger      lignes de remboursement connues (type refund) liées à une commande
 */
function analyzeLegacyEkOrders({ orders, debits, creditedOrderIds = [], refundLedger = [] }) {
  const credited = new Set(creditedOrderIds);
  const refunded = new Set(refundLedger.map((r) => r.orderId).filter(Boolean));
  const legacy = orders
    .filter((o) => !isServerProcessed(o) && o.paymentMethod === 'wallet')
    .sort((a, b) => (toMs(a.createdAt) ?? 0) - (toMs(b.createdAt) ?? 0));

  // Appariement un-pour-un : un même débit ne justifie jamais deux commandes.
  const usedDebits = new Set();
  const rows = [];
  for (const o of legacy) {
    const created = toMs(o.createdAt);
    const candidates = debits.filter((d) => d.uid === o.clientId && -d.amount === o.amount
      && !usedDebits.has(d.id)
      && created !== null && toMs(d.createdAt) !== null
      && toMs(d.createdAt) <= created + 60000 && toMs(d.createdAt) >= created - WINDOW_MS);
    candidates.sort((a, b) => Math.abs(created - toMs(a.createdAt)) - Math.abs(created - toMs(b.createdAt)));
    let evidence = 'none';
    let debitId = null;
    if (candidates.length === 1) { evidence = 'single_candidate'; debitId = candidates[0].id; usedDebits.add(debitId); }
    else if (candidates.length > 1) { evidence = 'ambiguous'; debitId = candidates[0].id; usedDebits.add(debitId); }

    const agentPaid = credited.has(o.id);
    const alreadyRefunded = refunded.has(o.id);
    let action;
    let note;
    if (o.status === 'cancelled') {
      if (alreadyRefunded) { action = 'none'; note = 'Remboursement déjà présent dans le journal.'; }
      else if (evidence === 'none') { action = 'verify_debit_first'; note = 'Annulée, aucun débit retrouvé : vérifier le relevé avant tout remboursement.'; }
      else { action = 'client_refund_to_decide'; note = 'Annulée sans remboursement et débit probable : à rembourser SI le débit est confirmé.'; }
    } else if (o.status === 'completed') {
      if (agentPaid && evidence === 'none') { action = 'agent_paid_without_debit_review'; note = 'Agent crédité sans débit retrouvé : vérifier, risque de création d\'argent.'; }
      else if (!agentPaid && evidence !== 'none') { action = 'agent_pay_to_decide'; note = 'Terminée, débit probable, aucun crédit agent tracé : à rémunérer SI le débit est confirmé.'; }
      else if (agentPaid) { action = 'none'; note = 'Débit probable et agent déjà crédité.'; }
      else { action = 'verify_debit_first'; note = 'Terminée, ni débit ni crédit retrouvés.'; }
    } else if (['cancelled', 'completed'].includes(o.status) === false) {
      action = evidence === 'none' ? 'verify_debit_first' : 'pending_order_follow_up';
      note = 'Commande non terminée : après déploiement, sa confirmation ne créditera pas l\'agent ; décider au cas par cas.';
    }
    rows.push({
      orderId: o.id, clientId: o.clientId, agentId: o.agentId ?? null, status: o.status, amount: o.amount,
      debitEvidence: evidence, debitCandidateId: debitId, agentCreditTraced: agentPaid,
      refundTraced: alreadyRefunded, action, note,
      // Clé stable pour tracer UNE décision par commande (empêche le double traitement).
      decisionKey: `ek_reconcile_${o.id}`,
    });
  }
  const count = (a) => rows.filter((r) => r.action === a).length;
  return {
    rows,
    summary: {
      legacyWalletOrders: rows.length,
      clientRefundToDecide: count('client_refund_to_decide'),
      agentPayToDecide: count('agent_pay_to_decide'),
      agentPaidWithoutDebitReview: count('agent_paid_without_debit_review'),
      verifyDebitFirst: count('verify_debit_first'),
      ambiguousDebit: rows.filter((r) => r.debitEvidence === 'ambiguous').length,
    },
  };
}

module.exports = { analyzeLegacyEkOrders, isServerProcessed };
