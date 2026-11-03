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

module.exports = { scanStuckOrders, scanOverdueCashRemittances, referenceMs, THRESHOLDS_MS, COLLECTION, CASH_REMITTANCE_DELAY_MS };
