'use strict';

// Port Node de lib/services/tarif_service.dart (TarifService.compute) —
// source unique de vérité tarifaire livraison (Master Prompt 51). Utilisé
// par les outils AZ IA de création de commande pour ne jamais laisser le
// modèle inventer un prix (contrairement au comportement précédent, qui
// laissait Claude choisir n'importe quel montant dans une large fourchette
// [500, 10000] sans aucun rapport avec la distance/l'heure réelles).
//
// Toute modification de la politique tarifaire doit être appliquée aux DEUX
// fichiers (Dart et Node) — ils doivent rester des ports fidèles l'un de
// l'autre, comme dispatch.js:calculateCommission l'est déjà de
// FirestoreService.calculateCommission().
//
// BUSINESS RULE:
// Livraison Express
// Jour = 1000 FCFA
// Nuit = 1500 FCFA
// Ne pas modifier sans décision métier.

const CENTER_LAT      = 6.7273;
const CENTER_LNG      = -3.4961;
const CITY_RADIUS_KM  = 8.0;
const EARTH_RADIUS_KM = 6371.0;

function toRad(deg) {
  return (deg * Math.PI) / 180;
}

function haversineKm(lat1, lng1, lat2, lng2) {
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Tarif nuit : 20h00-05h59
function isNightTime(time) {
  const t = time || new Date();
  const h = t.getHours();
  return h >= 20 || h < 6;
}

// Refus commandes >10 km : uniquement après 21h00
function isLateNight(time) {
  const t = time || new Date();
  return t.getHours() >= 21;
}

function round50(value) {
  const raw = Math.round(value);
  return Math.floor((raw + 24) / 50) * 50;
}

// { clientLat, clientLng, routeDistanceKm?, time? } -> {
//   standardPrice, expressPrice, isNight, isOutside, canOrder, rejectionMessage?
// }
function compute({ clientLat, clientLng, routeDistanceKm, time }) {
  const night     = isNightTime(time);
  const lateNight = isLateNight(time);
  const distFromCenter = haversineKm(CENTER_LAT, CENTER_LNG, clientLat, clientLng);
  const isOutside = distFromCenter > CITY_RADIUS_KM;

  if (!isOutside) {
    return {
      standardPrice: night ? 1000 : 500,
      // BUSINESS RULE:
      // Livraison Express
      // Jour = 1000 FCFA
      // Nuit = 1500 FCFA
      // Ne pas modifier sans décision métier.
      expressPrice:  night ? 1500 : 1000,
      isNight: night,
      isOutside: false,
      canOrder: true,
    };
  }

  const dist = typeof routeDistanceKm === 'number' && routeDistanceKm > 0
    ? routeDistanceKm
    : distFromCenter;

  if (lateNight && dist > 10) {
    return {
      standardPrice: 0,
      expressPrice: 0,
      isNight: true,
      isOutside: true,
      canOrder: false,
      rejectionMessage: "Livraison non disponible après 21h00 pour les zones à plus de 10 km d'Abengourou.",
    };
  }

  const stdRaw = 500.0 + dist * 150;
  const std    = round50(stdRaw);
  const exp    = round50(std * 1.4);

  return {
    standardPrice: std,
    expressPrice:  exp,
    isNight: night,
    isOutside: true,
    canOrder: true,
  };
}

module.exports = { compute, haversineKm, isNightTime, isLateNight, CENTER_LAT, CENTER_LNG, CITY_RADIUS_KM };
