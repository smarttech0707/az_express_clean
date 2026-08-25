'use strict';

const crypto = require('crypto');

function normalizeText(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function stableGuardKey(guard) {
  if (guard.sourceName && guard.externalId) {
    return `${normalizeText(guard.sourceName)}|${String(guard.externalId).trim()}`;
  }
  return [guard.sourceType || 'external', normalizeText(guard.name),
    normalizeText(guard.city), new Date(guard.guardStartAt).toISOString(),
    new Date(guard.guardEndAt).toISOString()].join('|');
}

function stableGuardId(guard) {
  return crypto.createHash('sha256').update(stableGuardKey(guard)).digest('hex').slice(0, 40);
}

function normalizeGuard(raw, sourceName) {
  const start = new Date(raw.guardStartAt);
  const end = new Date(raw.guardEndAt);
  if (!raw.name || !raw.city || Number.isNaN(start.getTime()) ||
      Number.isNaN(end.getTime()) || end <= start) {
    throw new Error('Garde invalide : nom, ville et période cohérente requis.');
  }
  return {
    externalId: raw.externalId ? String(raw.externalId) : null,
    name: String(raw.name).trim(),
    city: String(raw.city).trim(),
    cityKey: normalizeText(raw.city),
    district: raw.district ? String(raw.district).trim() : null,
    address: raw.address ? String(raw.address).trim() : null,
    phone: raw.phone ? String(raw.phone).trim() : null,
    latitude: Number.isFinite(Number(raw.latitude)) ? Number(raw.latitude) : null,
    longitude: Number.isFinite(Number(raw.longitude)) ? Number(raw.longitude) : null,
    guardStartAt: start,
    guardEndAt: end,
    sourceType: 'external',
    sourceName,
    sourceUrl: raw.sourceUrl || null,
    isVerified: raw.isVerified === true,
    isActive: raw.isActive !== false,
    linkedPartner: false,
    partnerPharmacyId: null,
  };
}

class PharmacyGuardProvider {
  async fetchGuards(_query) {
    throw new Error('fetchGuards doit être implémenté.');
  }
}

class DisabledExternalPharmacyGuardProvider extends PharmacyGuardProvider {
  constructor(reason = 'Aucune API officielle autorisée configurée.') {
    super();
    this.reason = reason;
    this.enabled = false;
  }
  async fetchGuards() {
    return { guards: [], available: false, reason: this.reason };
  }
}

async function syncProvider({ db, admin, provider, city, from, to, logger = console }) {
  const result = await provider.fetchGuards({ city, from, to });
  if (!result.available) {
    logger.info('Synchronisation gardes ignorée : provider indisponible.', { reason: result.reason });
    return { available: false, upserted: 0, reason: result.reason };
  }
  const guards = result.guards.map((raw) => normalizeGuard(raw, result.sourceName));
  let upserted = 0;
  for (const guard of guards) {
    const id = stableGuardId(guard);
    await db.collection('pharmacy_guards').doc(id).set({
      ...guard,
      guardStartAt: admin.firestore.Timestamp.fromDate(guard.guardStartAt),
      guardEndAt: admin.firestore.Timestamp.fromDate(guard.guardEndAt),
      dedupeKey: stableGuardKey(guard),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    upserted++;
  }
  return { available: true, upserted };
}

module.exports = {
  PharmacyGuardProvider,
  DisabledExternalPharmacyGuardProvider,
  normalizeText,
  normalizeGuard,
  stableGuardKey,
  stableGuardId,
  syncProvider,
};
