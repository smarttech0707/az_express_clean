'use strict';

const { readAmounts } = require('./orderAmounts');

// Chemins de remboursement automatiques d'`orders` (extraits de index.js pour
// être testés : autoExpireOrders et enforceOrderRateLimit). Les deux ne
// concernent que des commandes NON récupérées (pending / broadcast / assigned) :
// aucune prestation n'a été réalisée, le remboursement est donc intégral
// (produits + livraison pour les montants explicites), et le vendeur
// Marketplace rend les produits qu'il avait reçus à la création (plafonné au
// solde : jamais de solde négatif).

const WAITING_STATUSES = ['pending', 'broadcast', 'assigned'];

// Montants à rembourser / reprendre selon la forme de la commande.
function refundAmounts(order) {
  const explicit = readAmounts(order);
  const total = explicit ? explicit.totalAmount : Number(order.budget || 0);
  return { total, sellerShare: explicit ? explicit.productAmount : total };
}

async function readSeller(tx, db, order, willRefund) {
  // 'boutique' est exclu : son paiement réel vit sur `boutique_orders`, remboursé
  // séparément (annulation client ou buildRefundExpiredBoutiqueOrder).
  const needs = willRefund && order.sellerId && order.sellerType === 'seller';
  if (!needs) return { ref: null, snap: null };
  const ref = db.collection('sellers').doc(order.sellerId);
  return { ref, snap: await tx.get(ref) };
}

function refundClientAndSeller(tx, { db, admin, order, orderId, seller, clientId, descriptions }) {
  const { total, sellerShare } = refundAmounts(order);
  const clientRef = db.collection('clients').doc(clientId);
  tx.update(clientRef, { wallet: admin.firestore.FieldValue.increment(total) });
  tx.set(clientRef.collection('wallet_transactions').doc(), {
    type: 'refund', amount: total, description: descriptions.client,
    orderId, createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  if (seller.ref && seller.snap.exists) {
    const w = Number(seller.snap.data().wallet || 0);
    const sellerDebit = Math.min(sellerShare, w);
    if (sellerDebit > 0) {
      tx.update(seller.ref, { wallet: w - sellerDebit });
      tx.set(seller.ref.collection('wallet_transactions').doc(), {
        type: 'debit', amount: sellerDebit, description: descriptions.seller,
        orderId, createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  return { refunded: total };
}

// autoExpireOrders : 10 minutes sans livreur. Renvoie { expired, refunded }.
async function expireOrderTx(tx, { db, admin, orderRef, orderId }) {
  const fresh = await tx.get(orderRef);
  if (!fresh.exists) return { expired: false };
  const order = fresh.data();

  // Un livreur a peut-être accepté entre-temps.
  if (!WAITING_STATUSES.includes(order.status)) return { expired: false };
  // Remise en file par un livreur : le délai de 10 min repart de la remise en file.
  const requeuedMs = order.requeuedAt?.toMillis?.();
  if (requeuedMs && Date.now() - requeuedMs < 10 * 60 * 1000) return { expired: false };

  const willRefund = order.paymentMethod === 'wallet' && order.isPaid === true;
  // Toutes les lectures avant toute écriture.
  const seller = await readSeller(tx, db, order, willRefund);

  tx.update(orderRef, {
    status: 'cancelled',
    cancelReason: 'no_driver_found',
    cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  let refunded = 0;
  if (willRefund) {
    ({ refunded } = refundClientAndSeller(tx, {
      db, admin, order, orderId, seller, clientId: order.clientId,
      descriptions: {
        client: 'Remboursement — aucun livreur disponible',
        seller: 'Commande expirée (aucun livreur) — reprise du paiement',
      },
    }));
  }

  // Métriques dispatching — compteur de la tranche horaire/zone.
  const today = new Date().toISOString().split('T')[0];
  const slot = Math.floor(new Date().getHours() / 3) * 3; // tranches de 3h
  const zone = order.pickupZone || order.deliveryZone || 'unknown';
  tx.set(db.collection('dispatch_metrics').doc(`${today}_${zone}_${slot}h`), {
    date: today,
    zone,
    serviceType: order.type || 'livraison',
    hourSlot: slot,
    noDriverFoundCount: admin.firestore.FieldValue.increment(1),
    lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { expired: true, refunded };
}

// enforceOrderRateLimit : annulation immédiate au-delà de 10 commandes/heure.
// `order` est l'instantané de création (isPaid / paymentMethod / montants).
async function rateLimitCancelTx(tx, { db, admin, orderRef, orderId, order, clientId }) {
  const fresh = await tx.get(orderRef);
  if (!fresh.exists || fresh.data().status !== 'pending') return { cancelled: false };

  const willRefund = order.paymentMethod === 'wallet' && order.isPaid === true;
  const seller = await readSeller(tx, db, order, willRefund);

  tx.update(orderRef, {
    status: 'cancelled',
    cancelReason: 'rate_limit_exceeded',
    cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  let refunded = 0;
  if (willRefund) {
    ({ refunded } = refundClientAndSeller(tx, {
      db, admin, order, orderId, seller, clientId,
      descriptions: {
        client: 'Remboursement — limite de commandes dépassée',
        seller: 'Commande annulée (limite de commandes) — reprise du paiement',
      },
    }));
  }
  return { cancelled: true, refunded };
}

module.exports = { expireOrderTx, rateLimitCancelTx, refundAmounts, WAITING_STATUSES };
