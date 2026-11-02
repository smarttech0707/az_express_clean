'use strict';

// Opérations sensibles sur un compte vendeur depuis l'administration
// (modification de fiche, activation/désactivation), côté serveur :
//   - permission `demandes_vendeurs` (ou super-admin), vérifiée ici ;
//   - champs limités à la fiche : jamais wallet, abonnement, VIP, statut ;
//   - chaque tentative (réussie, refusée, échouée) est journalisée dans
//     `audit_logs` avec l'identité de l'admin, l'identifiant du vendeur et
//     l'heure serveur. Les anciennes/nouvelles valeurs ne portent que des
//     champs non sensibles ; le téléphone n'est signalé que par un booléen.
// Aucun mot de passe, jeton ni donnée financière n'est lu ni écrit ici.

const PROFILE_FIELDS = Object.freeze(['name', 'phone', 'type', 'isActive', 'lat', 'lng']);
// Seuls champs dont l'ancienne/nouvelle valeur peut figurer dans le journal.
const LOGGED_VALUE_FIELDS = Object.freeze(['name', 'type', 'isActive', 'lat', 'lng']);
const ACTIONS = new Set(['updateProfile', 'setActive']);

const envelope = (message, data = null) => ({ success: true, error: null, message, data, code: 'OK' });

function buildManageSellerAccount({
  db, admin, HttpsError, requireAdminPermission, checkRateLimit, logAudit,
}) {
  const FieldValue = admin.firestore.FieldValue;

  function validateProfile(profile) {
    if (!profile || typeof profile !== 'object' || Array.isArray(profile)) {
      throw new HttpsError('invalid-argument', 'Fiche vendeur invalide.');
    }
    const unknown = Object.keys(profile).filter((key) => !PROFILE_FIELDS.includes(key));
    if (unknown.length) {
      throw new HttpsError('invalid-argument', `Champ non modifiable : ${unknown[0].slice(0, 30)}`);
    }
    const out = {};
    if ('name' in profile) {
      const name = typeof profile.name === 'string' ? profile.name.trim() : '';
      if (name.length < 2 || name.length > 80) throw new HttpsError('invalid-argument', 'Nom invalide.');
      out.name = name;
    }
    if ('phone' in profile) {
      const phone = typeof profile.phone === 'string' ? profile.phone.replace(/[\s.-]/g, '') : '';
      if (!/^\+?\d{8,15}$/.test(phone)) throw new HttpsError('invalid-argument', 'Téléphone invalide.');
      out.phone = phone;
    }
    if ('type' in profile) {
      if (typeof profile.type !== 'string' || !/^[a-z_]{2,30}$/.test(profile.type)) {
        throw new HttpsError('invalid-argument', 'Type de vendeur invalide.');
      }
      out.type = profile.type;
    }
    if ('isActive' in profile) {
      if (typeof profile.isActive !== 'boolean') throw new HttpsError('invalid-argument', 'Statut invalide.');
      out.isActive = profile.isActive;
    }
    if ('lat' in profile || 'lng' in profile) {
      const { lat, lng } = profile;
      if (typeof lat !== 'number' || typeof lng !== 'number' || !Number.isFinite(lat) || !Number.isFinite(lng) ||
          lat < -90 || lat > 90 || lng < -180 || lng > 180 || (lat === 0 && lng === 0)) {
        throw new HttpsError('invalid-argument', 'Point GPS invalide.');
      }
      out.lat = lat;
      out.lng = lng;
    }
    if (!Object.keys(out).length) throw new HttpsError('invalid-argument', 'Aucune modification.');
    return out;
  }

  return async (request) => {
    const uid = request.auth?.uid || null;
    const data = request.data || {};
    const action = data.action;
    const sellerId = typeof data.sellerId === 'string' ? data.sellerId.trim() : '';
    const base = { userId: uid, userType: 'admin', targetId: sellerId || null };

    // Refus de permission : tracé avant de relancer l'erreur.
    try {
      await requireAdminPermission({ request, db, permission: 'demandes_vendeurs' });
    } catch (error) {
      await logAudit({ ...base, action: 'seller_account_denied', status: 'denied',
        metadata: { operation: String(action).slice(0, 30), code: error.code || 'unknown' } });
      throw error;
    }

    try {
      if (!ACTIONS.has(action) || !sellerId || sellerId.includes('/') || sellerId.length > 128) {
        throw new HttpsError('invalid-argument', 'Opération ou vendeur invalide.');
      }
      await checkRateLimit(uid, 'manage_seller_account', 30, 3600);
      const changes = action === 'setActive'
        ? validateProfile({ isActive: data.isActive })
        : validateProfile(data.profile);

      const sellerRef = db.collection('sellers').doc(sellerId);
      const result = await db.runTransaction(async (tx) => {
        const snap = await tx.get(sellerRef);
        if (!snap.exists) throw new HttpsError('not-found', 'Vendeur introuvable.');
        const current = snap.data() || {};
        if (changes.isActive === true && (current.deletionRequested === true || current.isDeleted === true)) {
          throw new HttpsError('failed-precondition', 'Compte en cours de suppression : activation impossible.');
        }
        const changed = Object.keys(changes).filter((key) => current[key] !== changes[key]);
        if (!changed.length) return { changed: [], before: {}, after: {} };
        const update = { updatedAt: FieldValue.serverTimestamp(), lastModifiedBy: uid };
        for (const key of changed) update[key] = changes[key];
        tx.update(sellerRef, update);
        const pick = (source) => Object.fromEntries(
          changed.filter((key) => LOGGED_VALUE_FIELDS.includes(key)).map((key) => [key, source[key] ?? null]));
        return { changed, before: pick(current), after: pick(changes) };
      });

      await logAudit({ ...base, action: action === 'setActive' ? 'seller_set_active' : 'seller_profile_update',
        status: 'success',
        metadata: { operation: action, changedFields: result.changed, before: result.before,
          after: result.after, phoneChanged: result.changed.includes('phone'), result: result.changed.length ? 'updated' : 'unchanged' } });
      return envelope(result.changed.length ? 'Compte vendeur mis à jour.' : 'Aucun changement.',
        { sellerId, changedFields: result.changed });
    } catch (error) {
      await logAudit({ ...base, action: 'seller_account_failed', status: 'failed',
        metadata: { operation: String(action).slice(0, 30), code: error.code || 'internal' } });
      throw error;
    }
  };
}

module.exports = { buildManageSellerAccount, PROFILE_FIELDS };
