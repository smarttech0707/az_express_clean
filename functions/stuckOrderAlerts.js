'use strict';

// Destinataires : administrateurs actifs, super-admin ou sous-admin porteur de la permission
// `commandes`. Volontairement local : ce chantier ne dépend d'aucun autre module de permissions.
const ALERT_PERMISSION = 'commandes';
function alertTokens(adminDocs) {
  const tokens = new Set();
  for (const doc of adminDocs) {
    const data = typeof doc?.data === 'function' ? doc.data() : doc;
    if (!data || data.isActive !== true) continue;
    const allowed = data.role === 'super' ||
      (data.role === 'sub' && Array.isArray(data.permissions) && data.permissions.includes(ALERT_PERMISSION));
    if (allowed && typeof data.fcmToken === 'string' && data.fcmToken.length > 10) tokens.add(data.fcmToken);
  }
  return [...tokens];
}

// I3 — alertes administratives sur les commandes bloquées après acceptation.
//
// LECTURE SEULE sur les commandes : ne modifie, n'annule, ne réattribue ni ne
// rembourse jamais une commande (surtout pas une commande `picked_up`). Elle
// prévient les administrateurs, qui décident (libération avant récupération,
// ou outil de litige après récupération).
//
// Anti-répétition : une alerte par épisode (commande + statut + instant de
// référence), garantie par la création atomique d'un document
// `stuck_order_alerts/{orderId}_{status}_{refMs}` (Admin SDK seul). Une commande
// ré-acceptée par un autre livreur ouvre un nouvel épisode ; la même commande ne
// notifie jamais deux fois.

const THRESHOLDS_MS = Object.freeze({
  accepted: 30 * 60 * 1000,
  picked_up: 90 * 60 * 1000,
});
const BATCH_LIMIT = 50;
const COLLECTION = 'stuck_order_alerts';

const millis = (v) => {
  if (!v) return null;
  if (typeof v.toMillis === 'function') return v.toMillis();
  return Number.isFinite(Number(v)) ? Number(v) : null;
};

// Instant de référence de l'épisode en cours.
function referenceMs(order) {
  const pick = (...vals) => vals.map(millis).find((m) => m != null) ?? null;
  return order.status === 'picked_up'
    ? pick(order.pickedUpAt, order.acceptedAt, order.requeuedAt, order.createdAt)
    : pick(order.acceptedAt, order.requeuedAt, order.createdAt);
}

async function scanStuckOrders({
  db, admin, sendToToken, logAudit, nowMs = Date.now(), logger = console,
}) {
  const summary = { scanned: 0, alerted: 0, duplicates: 0, errors: 0 };
  for (const status of Object.keys(THRESHOLDS_MS)) {
    let docs;
    try {
      const cutoff = admin.firestore.Timestamp.fromMillis(nowMs - THRESHOLDS_MS[status]);
      const snap = await db.collection('orders')
        .where('status', '==', status)
        .where('createdAt', '<=', cutoff)
        .limit(BATCH_LIMIT)
        .get();
      docs = snap.docs;
    } catch (err) {
      summary.errors += 1;
      logger.error(`[stuckOrders] lecture ${status} impossible : ${err.message}`);
      continue;
    }
    for (const doc of docs) {
      summary.scanned += 1;
      try {
        const order = doc.data();
        const ref = referenceMs(order);
        if (ref == null || nowMs - ref < THRESHOLDS_MS[status]) continue;
        const alertRef = db.collection(COLLECTION).doc(`${doc.id}_${status}_${ref}`);
        try {
          await alertRef.create({
            orderId: doc.id, status, referenceMs: ref, alertedAtMs: nowMs,
            driverId: order.driverId || null, minutes: Math.round((nowMs - ref) / 60000),
          });
        } catch (err) {
          if (/already exists|ALREADY_EXISTS|existant|exists/i.test(String(err.message || err.code))) {
            summary.duplicates += 1;
            continue;
          }
          throw err;
        }
        summary.alerted += 1;
        const minutes = Math.round((nowMs - ref) / 60000);
        const admins = await db.collection('admins').where('isActive', '==', true).get();
        const tokens = alertTokens(admins.docs);
        const title = status === 'picked_up' ? 'Commande récupérée bloquée' : 'Commande acceptée sans suite';
        const body = status === 'picked_up'
          ? `Colis récupéré depuis ${minutes} min sans livraison. Examinez la commande (aucune action automatique).`
          : `Course acceptée depuis ${minutes} min sans récupération. Contactez le livreur ou libérez la course.`;
        await Promise.all(tokens.map((token) => sendToToken(token, title, body, {
          type: 'stuck_order', orderId: doc.id, status,
        }).catch(() => {})));
        await logAudit({
          userId: 'system', userType: 'system', action: 'stuck_order_alert', targetId: doc.id,
          status: 'success', metadata: { status, minutes, notified: tokens.length },
        });
      } catch (err) {
        summary.errors += 1;
        logger.error(`[stuckOrders] ${doc.id} : ${err.message}`);
      }
    }
  }
  if (summary.alerted || summary.errors) logger.log(`[stuckOrders] ${JSON.stringify(summary)}`);
  return summary;
}

// Mission 7B-3B-C — reversement cash des commandes Restaurant/Boulangerie v2 en retard (plus de 24 h après la livraison,
// ni confirmé ni contesté). ALERTE SEULE : aucune sanction, aucun débit, aucune écriture sur la commande. Une alerte par
// commande (document déterministe créé atomiquement). Requête sur un seul champ (pas d'index composite) ; le filtre de
// retard se fait en mémoire. Les reversements contestés sont déjà visibles côté administration (statut disputed).
const CASH_REMITTANCE_DELAY_MS = 24 * 60 * 60 * 1000;

async function scanOverdueCashRemittances({
  db, sendToToken, logAudit, nowMs = Date.now(), logger = console,
}) {
  const summary = { scanned: 0, alerted: 0, duplicates: 0, errors: 0 };
  let docs;
  try {
    const snap = await db.collection('orders').where('cashRemittance.status', 'in', ['pending', 'declared']).limit(BATCH_LIMIT).get();
    docs = snap.docs;
  } catch (err) {
    summary.errors += 1;
    logger.error(`[cashRemittance] lecture impossible : ${err.message}`);
    return summary;
  }
  for (const doc of docs) {
    summary.scanned += 1;
    try {
      const order = doc.data();
      const r = order.cashRemittance || {};
      const since = millis(r.deliveredAtMs);
      if (order.amountsVersion !== 2 || order.status !== 'delivered' || since == null || nowMs - since <= CASH_REMITTANCE_DELAY_MS) continue;
      const alertRef = db.collection(COLLECTION).doc(`${doc.id}_cash_remittance_${since}`);
      try {
        await alertRef.create({
          orderId: doc.id, type: 'cash_remittance_overdue', referenceMs: since, alertedAtMs: nowMs,
          partnerId: order.sellerId || null, driverId: order.driverId || null, amountDue: r.amountDue ?? null,
          hours: Math.round((nowMs - since) / 3600000),
        });
      } catch (err) {
        if (/already exists|ALREADY_EXISTS|existant|exists/i.test(String(err.message || err.code))) {
          summary.duplicates += 1;
          continue;
        }
        throw err;
      }
      summary.alerted += 1;
      const hours = Math.round((nowMs - since) / 3600000);
      const admins = await db.collection('admins').where('isActive', '==', true).get();
      const tokens = alertTokens(admins.docs);
      await Promise.all(tokens.map((token) => sendToToken(token, 'Reversement cash en retard',
        `Produits en espèces non confirmés depuis ${hours} h (${r.amountDue ?? '?'} FCFA). Aucune action automatique : contactez le livreur et le partenaire.`,
        { type: 'cash_remittance_overdue', orderId: doc.id }).catch(() => {})));
      await logAudit({
        userId: 'system', userType: 'system', action: 'cash_remittance_overdue_alert', targetId: doc.id,
        status: 'success', metadata: { hours, notified: tokens.length },
      });
    } catch (err) {
      summary.errors += 1;
      logger.error(`[cashRemittance] ${doc.id} : ${err.message}`);
    }
  }
  if (summary.alerted || summary.errors) logger.log(`[cashRemittance] ${JSON.stringify(summary)}`);
  return summary;
}

// Mission 7C-1 — commandes Restaurant/Boulangerie v2 en attente. Une v2 n'expire plus tant que le partenaire n'a pas répondu
// ni tant que la préparation est lancée : ces attentes sont rendues VISIBLES par une alerte administrative (aucune
// annulation automatique avant 60 min). Deux types, une alerte par commande et par type (document déterministe) :
//   partner_no_response : v2 pending, jamais acceptée, 10 min après la création (annulée et remboursée à 60 min, orderRefunds).
//   prepared_no_driver  : v2 acceptée, préparation commencée, aucun livreur, 10 min après l'acceptation (ou la remise en file).
const PARTNER_WAIT_MS = 10 * 60 * 1000;

async function scanPartnerOrderWaits({
  db, sendToToken, logAudit, nowMs = Date.now(), logger = console,
}) {
  const summary = { scanned: 0, alerted: 0, duplicates: 0, errors: 0 };
  let docs;
  try {
    const snap = await db.collection('orders').where('amountsVersion', '==', 2).where('status', 'in', ['pending', 'broadcast']).limit(BATCH_LIMIT).get();
    docs = snap.docs;
  } catch (err) {
    summary.errors += 1;
    logger.error(`[partnerWaits] lecture impossible : ${err.message}`);
    return summary;
  }
  for (const doc of docs) {
    summary.scanned += 1;
    try {
      const o = doc.data();
      if (o.amountsVersion !== 2 || o.driverId) continue;
      let type = null; let since = null;
      if (!o.partnerAcceptedAtMs) {
        since = millis(o.createdAt);
        if (o.status === 'pending' && since != null && nowMs - since >= PARTNER_WAIT_MS) type = 'partner_no_response';
      } else if (o.sellerStatus === 'preparing' || o.sellerStatus === 'ready') {
        since = Math.max(millis(o.partnerAcceptedAtMs) || 0, millis(o.requeuedAt) || 0) || null;
        if (since != null && nowMs - since >= PARTNER_WAIT_MS) type = 'prepared_no_driver';
      }
      if (!type) continue;
      try {
        await db.collection(COLLECTION).doc(`${doc.id}_${type}_${since}`).create({
          orderId: doc.id, type, referenceMs: since, alertedAtMs: nowMs,
          partnerId: o.sellerId || null, minutes: Math.round((nowMs - since) / 60000),
        });
      } catch (err) {
        if (/already exists|ALREADY_EXISTS|existant|exists/i.test(String(err.message || err.code))) { summary.duplicates += 1; continue; }
        throw err;
      }
      summary.alerted += 1;
      const minutes = Math.round((nowMs - since) / 60000);
      const body = type === 'partner_no_response'
        ? `Le partenaire n’a pas répondu à une commande depuis ${minutes} min. Annulation et remboursement automatiques à 60 min sans réponse.`
        : `Commande préparée sans livreur depuis ${minutes} min. Aucune annulation automatique : contactez le partenaire et le client.`;
      const admins = await db.collection('admins').where('isActive', '==', true).get();
      const tokens = alertTokens(admins.docs);
      await Promise.all(tokens.map((token) => sendToToken(token, 'Commande partenaire en attente', body,
        { type, orderId: doc.id }).catch(() => {})));
      await logAudit({
        userId: 'system', userType: 'system', action: `${type}_alert`, targetId: doc.id,
        status: 'success', metadata: { minutes, notified: tokens.length },
      });
    } catch (err) {
      summary.errors += 1;
      logger.error(`[partnerWaits] ${doc.id} : ${err.message}`);
    }
  }
  if (summary.alerted || summary.errors) logger.log(`[partnerWaits] ${JSON.stringify(summary)}`);
  return summary;
}

module.exports = { scanStuckOrders, scanOverdueCashRemittances, scanPartnerOrderWaits, PARTNER_WAIT_MS, referenceMs, THRESHOLDS_MS, COLLECTION, CASH_REMITTANCE_DELAY_MS };
