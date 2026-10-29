'use strict';

// Partage des gains d'une course transférée entre livreurs (Phase 3).
//
// Règle validée : la rémunération disponible après la commission AZ est répartie
// proportionnellement à la distance utile validée de chaque livreur.
//
// Distance utile d'un livreur = progression vers la destination entre son point
// de prise en charge et son point de remise (distance à vol d'oiseau, jamais
// négative). Un détour, un aller-retour ou un recul n'ajoute donc aucun
// kilomètre payé. Les points viennent exclusivement de données serveur :
// pickup/destination de la commande, positions GPS des DEUX livreurs capturées
// à la remise confirmée par QR/PIN (fraîches et cohérentes entre elles).
//
// Une donnée manquante ou douteuse n'est JAMAIS remplacée par un pourcentage :
// le dossier passe en validation administrative, sans part proposée.
//
// Argent : les parts sont des entiers FCFA (méthode du plus fort reste) dont la
// somme est EXACTEMENT le montant réparti. Le payeur de la commission (déjà
// débité à l'acceptation) en est remboursé en tête : le total versé aux livreurs
// est le prix payé, et AZ conserve la seule commission prélevée.

const ALGORITHM = 'progress_toward_destination_v1';
const MAX_HANDOVER_SEPARATION_M = 500; // A et B doivent être au même endroit
const MAX_GPS_AGE_MS = 3 * 60 * 1000; // même fraîcheur que le dispatch
const REVIEW_DEADLINE_MS = 24 * 60 * 60 * 1000;

const isCoord = (lat, lng) => Number.isFinite(lat) && Number.isFinite(lng) &&
  Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat === 0 && lng === 0);

function haversineM(a, b) {
  const R = 6371000;
  const rad = (x) => (x * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

// Plus fort reste, en entiers : somme exacte, déterministe (égalité -> plus grand
// poids, puis premier index).
function allocate(total, weights) {
  if (!Number.isSafeInteger(total) || total < 0) throw new Error('total invalide');
  const w = weights.map((x) => Math.round(x));
  if (w.some((x) => !Number.isSafeInteger(x) || x < 0)) throw new Error('poids invalides');
  const sum = w.reduce((a, b) => a + b, 0);
  if (sum <= 0) return null;
  const parts = w.map((x, i) => {
    const num = total * x;
    return { i, base: Math.floor(num / sum), rem: num % sum, weight: x };
  });
  let left = total - parts.reduce((a, p) => a + p.base, 0);
  [...parts].sort((p, q) => q.rem - p.rem || q.weight - p.weight || p.i - q.i)
    .forEach((p) => { if (left > 0) { p.base += 1; left -= 1; } });
  return parts.map((p) => p.base);
}

// Point de remise fiable, capturé par le serveur au moment de la confirmation.
// `a`/`b` : { lat, lng, updatedAtMs } lus sur les documents livreurs.
function captureHandoverPoint(a, b, nowMs) {
  const reasons = [];
  const fresh = (p) => p && isCoord(p.lat, p.lng) && Number.isFinite(p.updatedAtMs) &&
    nowMs - p.updatedAtMs <= MAX_GPS_AGE_MS && p.updatedAtMs <= nowMs + 60000;
  if (!fresh(a)) reasons.push('gps_from_driver_stale_or_missing');
  if (!fresh(b)) reasons.push('gps_to_driver_stale_or_missing');
  let separationM = null;
  if (reasons.length === 0) {
    separationM = Math.round(haversineM(a, b));
    if (separationM > MAX_HANDOVER_SEPARATION_M) reasons.push('gps_drivers_too_far_apart');
  }
  return {
    trusted: reasons.length === 0,
    reasons,
    separationM,
    from: a ? { lat: a.lat ?? null, lng: a.lng ?? null, updatedAtMs: a.updatedAtMs ?? null } : null,
    to: b ? { lat: b.lat ?? null, lng: b.lng ?? null, updatedAtMs: b.updatedAtMs ?? null } : null,
    point: reasons.length === 0
      ? { lat: (a.lat + b.lat) / 2, lng: (a.lng + b.lng) / 2 } : null,
    capturedAtMs: nowMs,
  };
}

// order : document de la commande LIVRÉE (avec driverHistory et driverId final).
// Retourne la proposition de règlement (sans effet de bord).
function buildProposal(order, { deliveredAtMs }) {
  const reasons = [];
  const total = Math.max(0, Math.floor(Number(order.budget || 0)));
  // Commande d'un partenaire : la signification de `budget` (frais de livraison ou
  // prix produit) dépend du type de commande — jamais réparti automatiquement.
  if (order.sellerId) reasons.push('partner_order_amount_semantics');
  const traced = order.commissionStatus === 'charged' &&
    Number.isSafeInteger(order.commissionAmount) && order.commissionAmount >= 0 &&
    typeof order.commissionPayerId === 'string' && order.commissionPayerId;
  const commission = traced ? order.commissionAmount : 0;
  const payerId = traced ? order.commissionPayerId : null;
  if (!traced) reasons.push('commission_untraced');
  if (commission > total) reasons.push('commission_exceeds_price');

  // Chaîne de livreurs ayant porté le colis : transferts après récupération,
  // dans l'ordre, puis le livreur final.
  const carried = (Array.isArray(order.driverHistory) ? order.driverHistory : [])
    .filter((h) => h && h.phase === 'after_pickup')
    .sort((x, y) => Number(x.endedAtMs || 0) - Number(y.endedAtMs || 0));
  const chain = [...carried.map((h) => h.driverId), order.driverId];
  if (chain.some((id) => typeof id !== 'string' || !id)) reasons.push('driver_chain_incomplete');
  if (new Set(chain).size !== chain.length) reasons.push('driver_appears_twice');
  if (payerId && !chain.includes(payerId)) reasons.push('commission_payer_not_in_chain');

  const pickup = { lat: Number(order.latitude), lng: Number(order.longitude) };
  const dest = { lat: Number(order.destLat), lng: Number(order.destLng) };
  if (!isCoord(pickup.lat, pickup.lng)) reasons.push('pickup_coordinates_missing');
  if (!isCoord(dest.lat, dest.lng)) reasons.push('destination_coordinates_missing');

  const points = [pickup];
  carried.forEach((h, i) => {
    const p = h.handover && h.handover.trusted === true ? h.handover.point : null;
    if (p && isCoord(p.lat, p.lng)) points.push({ lat: p.lat, lng: p.lng });
    else { points.push(null); reasons.push(`handover_gps_untrusted:${i + 1}`); }
  });
  points.push(dest);

  const evidence = {
    pickupProof: order.pickupProofValidatedAt != null || order.pickedUpAt != null,
    handoverProofs: carried.length > 0 && carried.every((h) => !!h.transferId),
    deliveryProof: order.deliveryProofValidatedAt != null || !!order.deliveryPhotoUrl ||
      !!order.deliveryPhoto,
  };
  if (!evidence.handoverProofs) reasons.push('handover_proof_missing');
  if (!evidence.deliveryProof) reasons.push('delivery_proof_missing');

  const legs = [];
  let usable = points.every(Boolean) && reasons.every((r) => r !== 'driver_chain_incomplete');
  if (usable && isCoord(dest.lat, dest.lng)) {
    for (let i = 0; i < chain.length; i++) {
      const from = points[i];
      const to = points[i + 1];
      const remainingBefore = haversineM(from, dest);
      const remainingAfter = i + 1 === chain.length ? 0 : haversineM(to, dest);
      const usefulM = Math.max(0, Math.round(remainingBefore - remainingAfter));
      legs.push({ driverId: chain[i], usefulM,
        straightLineM: Math.round(haversineM(from, to)) });
    }
    if (legs.some((l) => l.usefulM <= 0)) { reasons.push('zero_useful_distance'); usable = false; }
  } else usable = false;

  const distributable = Math.max(0, total - commission);
  let shares = null;
  if (usable && reasons.length === 0) {
    const parts = allocate(distributable, legs.map((l) => l.usefulM));
    shares = legs.map((l, i) => ({ driverId: l.driverId, usefulM: l.usefulM, share: parts[i] }));
  }
  const credits = {};
  if (shares) {
    shares.forEach((s) => { credits[s.driverId] = s.share; });
    credits[payerId] = (credits[payerId] || 0) + commission;
  }

  return {
    algorithm: ALGORITHM,
    totalPaid: total,
    commission: { amount: commission, payerId },
    distributable,
    chain,
    legs,
    shares,
    // Montants à verser (part + remboursement du payeur de la commission).
    credits: shares ? credits : null,
    evidence,
    needsReview: reasons.length > 0,
    reasons,
    dueAtMs: deliveredAtMs + REVIEW_DEADLINE_MS,
    waypoints: points.map((p) => (p ? { lat: p.lat, lng: p.lng } : null)),
  };
}

// Document de règlement (collection transfer_settlements, écriture serveur
// uniquement). Toujours créé 'pending_review' : aucun gain n'est versé sans
// validation administrative.
function settlementDocument(orderId, order, method, nowMs) {
  const proposal = buildProposal(order, { deliveredAtMs: nowMs });
  return {
    orderId, method, status: 'pending_review', proposal,
    driverIds: proposal.chain, clientId: order.clientId || null,
    holderDriverId: order.driverId || null,
    totalPaid: proposal.totalPaid, createdAtMs: nowMs, dueAtMs: proposal.dueAtMs,
    decisions: [],
    ...(method === 'cash'
      ? { cash: { collected: proposal.totalPaid, status: 'not_started', confirmations: {} } } : {}),
  };
}

module.exports = {
  settlementDocument,
  ALGORITHM, MAX_HANDOVER_SEPARATION_M, MAX_GPS_AGE_MS, REVIEW_DEADLINE_MS,
  haversineM, allocate, captureHandoverPoint, buildProposal,
};
