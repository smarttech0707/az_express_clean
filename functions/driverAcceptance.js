'use strict';

const { readDriverState, runLifecycleTransaction } = require('./driverLifecycle');
const { isLegacyPartnerOrder, getLegacyPartnerPolicy } = require('./legacyPartnerPolicy');

// Acceptation d'une course par un livreur — côté SERVEUR.
//
// Avant ce module, la commission AZ était prélevée par une transaction
// Flutter (FirestoreService.acceptOrder) : le montant du portefeuille et le
// calcul de la commission venaient du client. Ici :
//   - la commission est calculée par le serveur (config/commission) ;
//   - le portefeuille est lu et débité dans UNE transaction avec la commande ;
//   - le prélèvement est identifié (`commission_<commande>_<livreur>`) et
//     tracé sur la commande (payeur, montant, transaction) : le remboursement
//     d'une annulation ou d'un transfert vise le payeur réel, jamais le livreur
//     courant par hypothèse ;
//   - un rejeu (double tap, reprise réseau) renvoie le succès sans redébiter.
// Aucun frais d'inscription : le portefeuille est un solde utilisable.

const ACCEPTABLE = new Set(['assigned', 'broadcast']);

// Selfie d'acceptation OBLIGATOIRE côté serveur : l'application l'impose à l'écran, mais seul le serveur est
// fiable (appel direct de la fonction sans photo, URL d'une autre commande ou d'un autre livreur). Chemin
// imposé par storage.rules : acceptance_selfies/<commande>/<uid du livreur>.jpg.
function selfiePath(orderId, uid) { return `acceptance_selfies/${orderId}/${uid}.jpg`; }

function selfieUrlMatches(url, orderId, uid) {
  if (typeof url !== 'string' || !url) return false;
  let decoded;
  try { decoded = decodeURIComponent(url); } catch (_) { return false; }
  // Le chemin doit être suivi de la fin de l'URL ou d'un paramètre : pas de préfixe trompeur (…/<uid>.jpg.evil).
  const marker = `/${selfiePath(orderId, uid)}`;
  const at = decoded.indexOf(marker);
  if (at < 0) return false;
  const next = decoded.charAt(at + marker.length);
  return next === '' || next === '?';
}

function buildAcceptOrder({
  db, admin, onCall, HttpsError, checkRateLimit, logAudit, calculateCommission,
  // (chemin) => Promise<boolean> : l'objet Storage existe réellement. Absent = contrôle d'URL seul (tests).
  selfieExists,
}) {
  return onCall(async (request) => {
    if (!request.auth?.uid ||
        request.auth.token?.firebase?.sign_in_provider === 'anonymous') {
      throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    }
    const uid = request.auth.uid;
    const { orderId: rawOrderId, acceptanceSelfieUrl, driverPhotoUrl } = request.data || {};
    if (typeof rawOrderId !== 'string' || !rawOrderId.trim() || rawOrderId.length > 128 ||
        rawOrderId.includes('/')) {
      throw new HttpsError('invalid-argument', 'orderId invalide');
    }
    for (const url of [acceptanceSelfieUrl, driverPhotoUrl]) {
      if (url !== undefined && url !== null && (typeof url !== 'string' || url.length > 2048)) {
        throw new HttpsError('invalid-argument', 'Photo invalide');
      }
    }
    const orderId = rawOrderId.trim();
    await checkRateLimit(uid, 'accept_order', 20, 60);

    const orderRef = db.collection('orders').doc(orderId);
    const driverRef = db.collection('livreurs').doc(uid);
    const legacyPolicy = await getLegacyPartnerPolicy(db);
    let outcome;

    await runLifecycleTransaction(db, async (tx) => {
      const [orderSnap, driverSnap, deletionSnap] = await Promise.all([
        tx.get(orderRef), tx.get(driverRef),
        tx.get(db.collection('account_deletions').doc(uid)),
      ]);
      if (!orderSnap.exists) throw new HttpsError('not-found', 'Commande introuvable');
      if (!driverSnap.exists) throw new HttpsError('permission-denied', 'Compte livreur introuvable');
      const order = orderSnap.data();
      const driver = driverSnap.data() || {};

      // Rejeu par le même livreur : succès sans second prélèvement.
      if (order.status === 'accepted' && order.driverId === uid &&
          order.commissionPayerId === uid) {
        outcome = { success: true, alreadyAccepted: true, commission: Number(order.commissionAmount || 0) };
        return;
      }
      if (!ACCEPTABLE.has(order.status)) {
        throw new HttpsError('failed-precondition', 'Cette commande n’est plus disponible');
      }
      // Placé après le rejeu : une reprise réseau sans photo ne doit pas échouer une acceptation déjà faite.
      if (!selfieUrlMatches(acceptanceSelfieUrl, orderId, uid) ||
          (selfieExists && !(await selfieExists(selfiePath(orderId, uid))))) {
        throw new HttpsError('failed-precondition', 'SELFIE_REQUIRED');
      }
      // Commande Marketplace/Boutique historique : aucun frais de livraison n'a été
      // encaissé, le livreur ne serait jamais rémunéré. Prélever une commission
      // serait un prélèvement sans contrepartie → acceptation bloquée (résolution
      // administrative ou mise à jour de l'application), sauf mode transitoire
      // 'no_commission' où la course est acceptée SANS commission.
      const legacyPartner = isLegacyPartnerOrder(order);
      if (legacyPartner && legacyPolicy === 'block') {
        throw new HttpsError('failed-precondition', 'LEGACY_PARTNER_ORDER');
      }
      // Un livreur qui a libéré cette commande ne peut pas la reprendre.
      if (Array.isArray(order.excludedDriverIds) && order.excludedDriverIds.includes(uid)) {
        throw new HttpsError('permission-denied', 'Vous avez libéré cette commande');
      }
      if (order.status === 'assigned' && order.driverId !== uid) {
        throw new HttpsError('permission-denied', 'Cette commande ne vous est pas assignée');
      }
      if (order.status === 'broadcast') {
        const notified = Array.isArray(order.notifiedDriverIds) ? order.notifiedDriverIds : [];
        if (!notified.includes(uid)) {
          throw new HttpsError('permission-denied', 'Cette commande ne vous a pas été proposée');
        }
      }
      // Même garde que l'ancienne règle Firestore (suppression de compte validée) :
      // un livreur dont la suppression est consentie n'accepte plus de mission.
      if (driver.deletionRequested === true ||
          (deletionSnap.exists && deletionSnap.data().consentVerified === true)) {
        throw new HttpsError('failed-precondition', 'Votre compte est en cours de suppression.');
      }
      if (driver.isSuspended === true) {
        throw new HttpsError('failed-precondition',
          'Votre compte a été suspendu, vous ne pouvez plus accepter de commandes.');
      }
      if (driver.isOnline !== true) {
        throw new HttpsError('failed-precondition', 'Vous devez être en ligne pour accepter une commande.');
      }
      const state = await readDriverState(tx, db, uid, orderId);
      if (driver.isOnDelivery === true || state.active > 0) {
        throw new HttpsError('failed-precondition', 'Vous avez déjà une livraison en cours.');
      }

      const budget = Number(order.budget || 0);
      const commission = legacyPartner
        ? 0
        : Math.max(0, Math.floor(Number(await calculateCommission(db, budget))));
      const wallet = Number(driver.wallet || 0);
      if (!Number.isSafeInteger(wallet) || wallet < commission) {
        const message = `CREDIT_INSUFFISANT:${Number.isFinite(wallet) ? wallet : 0}:${commission}`;
        throw new HttpsError('failed-precondition', message, { wallet, commission });
      }

      const txId = `commission_${orderId}_${uid}`;
      const txRef = driverRef.collection('wallet_transactions').doc(txId);
      const FieldValue = admin.firestore.FieldValue;
      tx.update(driverRef, { wallet: wallet - commission, isOnDelivery: true });
      if (commission > 0) {
        tx.set(txRef, {
          type: 'commission', amount: commission, orderId,
          description: `Commission AZ Express — course ${String(order.description || '').split('\n')[0]} (${budget} FCFA)`,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      tx.update(orderRef, {
        status: 'accepted',
        driverId: uid,
        acceptedAt: FieldValue.serverTimestamp(),
        notifiedDriverIds: FieldValue.delete(),
        commissionAmount: commission,
        commissionPayerId: uid,
        commissionTxId: commission > 0 ? txId : null,
        commissionStatus: 'charged',
        ...(legacyPartner ? { commissionWaivedReason: 'legacy_partner_order' } : {}),
        ...(acceptanceSelfieUrl ? { driverAcceptanceSelfie: acceptanceSelfieUrl } : {}),
        ...(driverPhotoUrl ? { driverPhotoUrl } : {}),
      });
      outcome = { success: true, alreadyAccepted: false, commission };
    });

    if (!outcome.alreadyAccepted) {
      await logAudit({
        userId: uid, userType: 'driver', action: 'accept_order', targetId: orderId,
        amount: outcome.commission || null, status: 'success',
        metadata: { commission: outcome.commission },
      });
    }
    return outcome;
  });
}

module.exports = { buildAcceptOrder };
