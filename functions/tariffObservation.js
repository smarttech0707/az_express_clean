'use strict';

const tarif = require('./tarifService');

// C2 — phase 0 : OBSERVATION des écarts de tarif, aucun blocage.
//
// Le prix d'une livraison est calculé par l'application ; le serveur ne le
// vérifie pas (voir known-issues). Cette phase journalise, sans jamais refuser
// ni modifier une commande, les budgets qui paraissent trop bas, afin de mesurer
// les faux positifs avant toute décision de blocage.
//
// Règles de prudence (pour ne pas confondre un client légitime avec une fraude) :
//  - Aucun appel Google Maps : la distance routière n'est jamais connue du
//    serveur. En zone centrale le prix est fixe ; hors zone il dépend de la
//    distance routière, supérieure ou égale à la distance à vol d'oiseau mais
//    mesurée par l'application depuis un autre point que le centre : on ne
//    déduit donc de plancher que de 500 FCFA (prix standard de jour).
//  - Seuil nuit/jour : l'application utilise l'horloge de l'appareil, le serveur
//    l'heure de création. Dans les 10 minutes autour de 20 h / 21 h on retient
//    le plancher le plus bas des deux.
//  - Seuls les types dont `budget` est le prix de livraison sont observés
//    (`shopping`, `livraison`). Restaurant (budget = total du repas),
//    Marketplace/Boutique (montants explicites), pharmacie et boulangerie sont
//    exclus de cette première phase.
//  - Aucune donnée personnelle : ni client, ni coordonnées, ni nom. Seulement
//    des montants, le type, l'heure et la distance au centre arrondie.

const OBSERVED_TYPES = new Set(['shopping', 'livraison']);
const BOUNDARY_WINDOW_MS = 10 * 60 * 1000;
const FLOOR_OUTSIDE_ZONE = 500;

const millis = (v) => {
  if (!v) return null;
  if (typeof v.toMillis === 'function') return v.toMillis();
  return Number.isFinite(Number(v)) ? Number(v) : null;
};

// Abidjan est en UTC (sans heure d'été) : l'heure du serveur est l'heure locale.
const atTime = (ms) => ({ getHours: () => new Date(ms).getUTCHours() });

function evaluateTariff(order, nowMs = Date.now()) {
  if (!order || !OBSERVED_TYPES.has(order.type)) return null;
  const budget = Number(order.budget);
  const lat = Number(order.destLat);
  const lng = Number(order.destLng);
  const createdMs = millis(order.createdAt) ?? nowMs;
  if (!Number.isFinite(budget) || !Number.isFinite(lat) || !Number.isFinite(lng) || (!lat && !lng)) return null;

  const samples = [createdMs - BOUNDARY_WINDOW_MS, createdMs, createdMs + BOUNDARY_WINDOW_MS]
    .map((ms) => tarif.compute({ clientLat: lat, clientLng: lng, time: atTime(ms) }));
  const main = samples[1];
  const floorOf = (r) => (r.isOutside ? FLOOR_OUTSIDE_ZONE : r.standardPrice);
  const expectedMin = Math.min(...samples.map(floorOf));
  const distKm = Math.round(tarif.haversineKm(tarif.CENTER_LAT, tarif.CENTER_LNG, lat, lng) * 10) / 10;

  let kind = null;
  if (!main.canOrder && samples.every((r) => !r.canOrder)) kind = 'forbidden_late_night';
  else if (budget < expectedMin) kind = 'below_minimum';
  else if (!main.isOutside) {
    const grid = new Set(samples.flatMap((r) => (r.canOrder ? [r.standardPrice, r.expressPrice] : [])));
    if (!grid.has(budget)) kind = 'off_grid_inside_zone';
  }
  if (!kind) return null;
  return {
    kind,
    type: order.type,
    budget,
    expectedMin,
    expectedStandard: main.canOrder ? main.standardPrice : null,
    expectedExpress: main.canOrder ? main.expressPrice : null,
    isNight: main.isNight,
    isOutside: main.isOutside,
    distanceFromCenterKm: distKm,
    createdAtMs: createdMs,
  };
}

// Journal idempotent (une fois par commande). Ne lève jamais.
async function recordTariffObservation(db, orderId, record, nowMs = Date.now()) {
  if (!record || typeof orderId !== 'string' || !orderId) return false;
  try {
    await db.collection('tariff_observations').doc(orderId).create({
      orderId, mode: 'observe', observedAtMs: nowMs, ...record,
    });
    return true;
  } catch (err) {
    if (!/already exists|ALREADY_EXISTS|existant|exists/i.test(String(err && (err.message || err.code)))) {
      console.warn(`[tariffObservation] ${orderId} : ${err.message}`);
    }
    return false;
  }
}

async function observeOrderTariff(db, orderId, order, nowMs = Date.now()) {
  try {
    return await recordTariffObservation(db, orderId, evaluateTariff(order, nowMs), nowMs);
  } catch (err) {
    console.warn(`[tariffObservation] ${orderId} : ${err.message}`);
    return false;
  }
}

module.exports = { evaluateTariff, recordTariffObservation, observeOrderTariff, OBSERVED_TYPES };
