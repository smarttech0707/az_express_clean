'use strict';

const { HttpsError } = require('firebase-functions/v2/https');

const DOC_ID_PATTERN = /^[A-Za-z0-9]{20}$/;
const SLUG_PATTERN = /^[a-z][a-z0-9_]{1,39}$/;
const PHONE_CHARS = /^[0-9+ .\-]+$/;
const MAX_PHOTOS = 10;

function text(value, label, { min = 0, max }) {
  const v = typeof value === 'string' ? value.trim() : '';
  if (v.length < min || v.length > max) {
    throw new HttpsError('invalid-argument', `${label} invalide`);
  }
  return v;
}

// L'appelant peut être non authentifié (inscription avant tout compte) : on ne
// fait donc jamais confiance au contenu, seulement à sa forme. Les photos ne
// sont acceptées que si elles pointent vers le dossier Storage de CETTE demande.
function sanitizeApplication(data) {
  const input = data && typeof data === 'object' ? data : {};
  const { docId } = input;
  if (docId !== undefined && !DOC_ID_PATTERN.test(String(docId))) {
    throw new HttpsError('invalid-argument', 'Identifiant de demande invalide');
  }

  const name = text(input.name, 'Nom', { min: 2, max: 100 });
  const phone = text(input.phone, 'Téléphone', { min: 8, max: 20 });
  const digits = phone.replace(/\D/g, '');
  if (!PHONE_CHARS.test(phone) || digits.length < 8 || digits.length > 15) {
    throw new HttpsError('invalid-argument', 'Téléphone invalide');
  }
  const address = text(input.address, 'Adresse', { min: 3, max: 200 });
  const description = input.description === undefined || input.description === null
    ? '' : text(input.description, 'Description', { max: 1000 });

  const subcategory = String(input.subcategory ?? '');
  if (!SLUG_PATTERN.test(subcategory)) {
    throw new HttpsError('invalid-argument', 'Métier invalide');
  }
  const category = input.category ? String(input.category) : 'artisans';
  if (!SLUG_PATTERN.test(category)) {
    throw new HttpsError('invalid-argument', 'Catégorie invalide');
  }

  let photos = [];
  if (input.photos !== undefined && input.photos !== null) {
    if (!Array.isArray(input.photos) || input.photos.length > MAX_PHOTOS) {
      throw new HttpsError('invalid-argument', 'Photos invalides');
    }
    const folder = docId === undefined ? null : `/o/service_providers%2F${docId}%2F`;
    photos = input.photos.map((url) => {
      const u = String(url);
      if (!folder || u.length > 600 || !u.startsWith('https://firebasestorage.googleapis.com/')
        || !u.includes(folder)) {
        throw new HttpsError('invalid-argument', 'Photo invalide');
      }
      return u;
    });
  }

  const coord = (v, limit) => (typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= limit ? v : 0);
  return {
    docId: docId === undefined ? undefined : String(docId),
    name, phone, address, description, subcategory, category, photos,
    lat: coord(input.lat, 90),
    lng: coord(input.lng, 180),
  };
}

// Limites : par numéro (réessais d'un même artisan) et, si le compte est
// identifié, par appareil/compte. Aucune limite globale : elle permettrait à un
// seul abuseur de bloquer toutes les inscriptions légitimes.
async function enforceApplicationLimits({ checkRateLimit, request, phone }) {
  await checkRateLimit(`sp_apply_${phone}`, 'service_provider_apply', 5, 3600);
  if (request.auth?.uid) {
    await checkRateLimit(request.auth.uid, 'service_provider_apply_uid', 5, 86400);
  }
}

module.exports = { sanitizeApplication, enforceApplicationLimits };
