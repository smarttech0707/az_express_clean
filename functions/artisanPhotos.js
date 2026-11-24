'use strict';

// Ajout / suppression de photos par un artisan.
//
// L'artisan n'a pas de compte Firebase personnel : après `artisanLogin` (téléphone + PIN vérifié côté serveur), sa
// session reste anonyme et `service_providers/{id}.artisanUid` mémorise cette session. Les règles Storage/Firestore
// exigent un utilisateur non anonyme pour écrire (volontairement : aucun droit d'écriture général aux anonymes), donc
// l'écriture directe depuis l'application était refusée. Ici l'écriture est faite par le serveur, et UNIQUEMENT si
// l'appelant est la session liée à ce profil — chaque artisan ne peut modifier que ses propres données.

const crypto = require('crypto');

const MAX_PHOTOS = 8;
const MAX_BYTES = 3 * 1024 * 1024;
const MAX_BASE64_CHARS = Math.ceil(MAX_BYTES / 3) * 4 + 8;

const envelope = (message, data) => ({ success: true, error: null, message, data, code: 'OK' });

function imageType(buffer) {
  if (buffer.length > 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'image/jpeg';
  if (buffer.length > 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  return null;
}

// Chemin d'objet d'une URL de téléchargement Firebase Storage (…/o/<chemin encodé>?alt=media&token=…).
function storagePathFromUrl(url) {
  if (typeof url !== 'string') return null;
  const match = /\/o\/([^?]+)/.exec(url);
  if (!match) return null;
  try { return decodeURIComponent(match[1]); } catch (_) { return null; }
}

function buildManageArtisanPhotos({ db, admin, bucket, onCall, HttpsError, checkRateLimit, logAudit, now = Date.now }) {
  return onCall(async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Connexion requise');
    const uid = request.auth.uid;
    const { action, docId, imageBase64, url } = request.data || {};
    if (!['add', 'delete'].includes(action)) throw new HttpsError('invalid-argument', 'Action invalide');
    if (typeof docId !== 'string' || !docId || docId.length > 128 || docId.includes('/')) {
      throw new HttpsError('invalid-argument', 'Profil invalide');
    }

    const ref = db.collection('service_providers').doc(docId);
    const first = await ref.get();
    const provider = first.exists ? first.data() : null;
    // Même message pour « inconnu » et « pas à vous » : pas d'énumération des profils.
    if (!provider || typeof provider.artisanUid !== 'string' || provider.artisanUid !== uid) {
      throw new HttpsError('permission-denied', 'Profil non autorisé');
    }
    if (provider.deletionRequested === true || provider.isDeleted === true) {
      throw new HttpsError('failed-precondition', 'Compte en cours de suppression');
    }
    await checkRateLimit(uid, 'artisan_photo', 30, 3600);

    if (action === 'add') {
      if (typeof imageBase64 !== 'string' || !imageBase64 || imageBase64.length > MAX_BASE64_CHARS) {
        throw new HttpsError('invalid-argument', 'Image invalide ou trop volumineuse (3 Mo maximum)');
      }
      const bytes = Buffer.from(imageBase64, 'base64');
      const contentType = bytes.length > 0 && bytes.length <= MAX_BYTES ? imageType(bytes) : null;
      if (!contentType) throw new HttpsError('invalid-argument', 'Image JPEG ou PNG requise (3 Mo maximum)');
      if ((Array.isArray(provider.photos) ? provider.photos.length : 0) >= MAX_PHOTOS) {
        throw new HttpsError('failed-precondition', `Maximum ${MAX_PHOTOS} photos`);
      }

      const extension = contentType === 'image/png' ? 'png' : 'jpg';
      const path = `service_providers/${docId}/photo_${now()}_${crypto.randomBytes(4).toString('hex')}.${extension}`;
      const token = crypto.randomUUID();
      await bucket.file(path).save(bytes, { contentType, metadata: { metadata: { firebaseStorageDownloadTokens: token } } });
      const photoUrl = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media&token=${token}`;

      try {
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(ref);
          const current = snap.exists ? snap.data() : null;
          if (!current || current.artisanUid !== uid) throw new HttpsError('permission-denied', 'Profil non autorisé');
          const photos = Array.isArray(current.photos) ? current.photos : [];
          if (photos.length >= MAX_PHOTOS) throw new HttpsError('failed-precondition', `Maximum ${MAX_PHOTOS} photos`);
          tx.update(ref, { photos: [...photos, photoUrl] });
        });
      } catch (error) {
        // Pas de fichier orphelin si l'enregistrement du profil échoue.
        try { await bucket.file(path).delete({ ignoreNotFound: true }); } catch (_) { /* meilleur effort */ }
        throw error;
      }
      await logAudit({ userId: uid, userType: 'artisan', action: 'artisan_photo_added', targetId: docId, status: 'success' });
      return envelope('Photo ajoutée', { url: photoUrl });
    }

    // delete : seule une photo DÉJÀ listée dans ce profil, rangée sous son propre dossier, peut être supprimée.
    const path = storagePathFromUrl(url);
    const folder = `service_providers/${docId}/`;
    if (!path || !path.startsWith(folder) || path.includes('..') || path.slice(folder.length).includes('/')) {
      throw new HttpsError('invalid-argument', 'Photo invalide');
    }
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const current = snap.exists ? snap.data() : null;
      if (!current || current.artisanUid !== uid) throw new HttpsError('permission-denied', 'Profil non autorisé');
      const photos = Array.isArray(current.photos) ? current.photos : [];
      if (!photos.includes(url)) throw new HttpsError('not-found', 'Photo introuvable dans votre profil');
      tx.update(ref, { photos: photos.filter((p) => p !== url) });
    });
    await bucket.file(path).delete({ ignoreNotFound: true });
    await logAudit({ userId: uid, userType: 'artisan', action: 'artisan_photo_deleted', targetId: docId, status: 'success' });
    return envelope('Photo supprimée', { url });
  });
}

module.exports = { buildManageArtisanPhotos, storagePathFromUrl, MAX_PHOTOS, MAX_BYTES };
