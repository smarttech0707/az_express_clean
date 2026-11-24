'use strict';

// SEC-01 / S6.8 — getDriverPhoneForOrderCF : conçue en S6.7
// (docs/SEC01_S6_7_PHONE_ACCESS_DESIGN_AUDIT.md), implémentée ici seule,
// sans migrer aucun lecteur Flutter/Web existant. Objectif : remplacer à
// terme les 7 lectures directes de `livreurs.phone` par un accès server-side
// contrôlé, sans jamais exposer `phone` dans `driver_public` ni dans
// `orders` (les deux restent lisibles par plus de rôles que nécessaire pour
// cette donnée — voir le rapport S6.7 §9).
//
// Principe non négociable : l'autorisation ne repose JAMAIS sur le seul
// `orderId` fourni par l'appelant. Le rôle de l'appelant est déterminé en
// relisant `orders/{orderId}` côté serveur et en comparant `request.auth.uid`
// à des champs du document (`clientId`, `sellerId`, `pharmacieId` →
// `pharmacies.currentUid`) ou à son statut super-admin (`admins/{uid}`),
// jamais à une affirmation du client. `driverId` est toujours relu depuis le
// document `orders` fraîchement chargé — jamais un paramètre d'entrée —
// pour renvoyer le bon numéro même après un transfert de livreur en cours de
// route (`driverTransfer.js`).

// Statuts actifs : un livreur est assigné et la commande est en cours.
const ACTIVE_STATUSES = new Set(['assigned', 'accepted', 'picked_up']);

// Fenêtre de grâce après livraison : un contact de dernière minute reste
// légitime quelques heures après `delivered` (ex. objet oublié), mais pas
// indéfiniment. Valeur ajustable séparément du code d'autorisation.
const DELIVERED_GRACE_MS = 2 * 60 * 60 * 1000; // 2 heures

function isWithinDeliveredGrace(order) {
  if (order.status !== 'delivered') return false;
  const deliveredAtMs = order.deliveredAt?.toMillis?.() ?? null;
  if (deliveredAtMs == null) return false;
  return Date.now() - deliveredAtMs <= DELIVERED_GRACE_MS;
}

// Un livreur assigné à la commande n'a, dans l'inventaire S6.5/S6.7, aucun
// écran qui lit le téléphone d'un AUTRE livreur ni le sien via ce mécanisme —
// exclu par défaut (S6.7 §5.B), pour ne pas élargir la matrice d'autorisation
// sans besoin identifié.
async function resolveRole({ db, uid, order }) {
  if (order.clientId === uid) {
    return 'client';
  }
  if (order.pharmacieId) {
    const pharmacieSnap = await db.collection('pharmacies').doc(String(order.pharmacieId)).get();
    if (pharmacieSnap.exists && pharmacieSnap.data()?.currentUid === uid) {
      return 'pharmacie';
    }
  }
  if (order.sellerId && order.sellerId === uid) {
    return 'partner';
  }
  const adminSnap = await db.collection('admins').doc(uid).get();
  const adminData = adminSnap.data();
  if (adminSnap.exists && adminData?.isActive === true && adminData?.role === 'super') {
    return 'admin';
  }
  return null;
}

function statusAllowsAccess(role, order) {
  if (role === 'admin') return true; // traçabilité/litige, cf. matrice S6.7 §6
  return ACTIVE_STATUSES.has(order.status) || isWithinDeliveredGrace(order);
}

// Message et code strictement identiques pour « commande inexistante » et
// « commande existante mais non autorisée » : empêche un appelant de
// distinguer les deux cas en sondant des orderId au hasard (S6.7 §7).
function deniedError(HttpsError) {
  return new HttpsError('permission-denied', 'Accès refusé pour cette commande.');
}

function buildGetDriverPhoneForOrder({ db, admin, onCall, HttpsError, checkRateLimit, logAudit }) {
  return onCall(async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté.');
    }
    const uid = request.auth.uid;

    const { orderId } = request.data || {};
    if (typeof orderId !== 'string' || orderId.trim().length === 0 || orderId.length > 200) {
      throw new HttpsError('invalid-argument', 'orderId invalide.');
    }
    const normalizedOrderId = orderId.trim();

    await checkRateLimit(uid, 'get_driver_phone_for_order', 20, 60);

    const orderSnap = await db.collection('orders').doc(normalizedOrderId).get();
    if (!orderSnap.exists) {
      await logAudit({
        userId: uid, userType: 'unknown', action: 'get_driver_phone_for_order',
        targetId: normalizedOrderId, status: 'denied', metadata: { reason: 'order_not_found' },
      });
      throw deniedError(HttpsError);
    }
    const order = orderSnap.data();

    const role = await resolveRole({ db, uid, order });
    if (!role) {
      await logAudit({
        userId: uid, userType: 'unknown', action: 'get_driver_phone_for_order',
        targetId: normalizedOrderId, status: 'denied', metadata: { reason: 'no_matching_role' },
      });
      throw deniedError(HttpsError);
    }

    if (!statusAllowsAccess(role, order)) {
      await logAudit({
        userId: uid, userType: role, action: 'get_driver_phone_for_order',
        targetId: normalizedOrderId, status: 'denied',
        metadata: { reason: 'status_not_allowed', orderStatus: order.status || null },
      });
      throw deniedError(HttpsError);
    }

    // `driverId` relu depuis CE document, jamais un paramètre d'entrée — reflète
    // toujours le livreur réellement assigné, y compris après un transfert.
    const driverId = order.driverId;
    if (!driverId) {
      await logAudit({
        userId: uid, userType: role, action: 'get_driver_phone_for_order',
        targetId: normalizedOrderId, status: 'denied', metadata: { reason: 'no_driver_assigned' },
      });
      throw new HttpsError('failed-precondition', "Aucun livreur n'est assigné à cette commande.");
    }

    const driverSnap = await db.collection('livreurs').doc(String(driverId)).get();
    const phone = driverSnap.exists ? driverSnap.data()?.phone : null;
    if (!phone) {
      await logAudit({
        userId: uid, userType: role, action: 'get_driver_phone_for_order',
        targetId: normalizedOrderId, status: 'denied',
        metadata: { reason: 'driver_phone_unavailable', driverId },
      });
      throw new HttpsError('not-found', 'Numéro indisponible.');
    }

    // Journalisation SANS le numéro : seulement le résultat et son contexte.
    await logAudit({
      userId: uid, userType: role, action: 'get_driver_phone_for_order',
      targetId: normalizedOrderId, status: 'success',
      metadata: { driverId, orderStatus: order.status || null },
    });

    return { success: true, data: { phone }, error: null, message: null, code: null };
  });
}

module.exports = {
  buildGetDriverPhoneForOrder,
  // Exportées pour les tests ciblés (logique pure, sans Cloud Function).
  ACTIVE_STATUSES,
  DELIVERED_GRACE_MS,
  isWithinDeliveredGrace,
  resolveRole,
  statusAllowsAccess,
};
