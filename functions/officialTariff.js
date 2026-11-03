'use strict';

// Moteur tarifaire OFFICIEL côté serveur (Phase 1, local, non branché).
//
// Entrées de confiance : heure du serveur, configuration (tariffConfig.js),
// coordonnées validées. Entrées JAMAIS crues : heure du téléphone, distance
// déclarée (bornée, jamais en dessous du vol d'oiseau), montant calculé par
// Flutter, prix unitaire fourni par le client.
//
// Parité : pour la configuration par défaut et une distance déclarée valide,
// les montants sont identiques à tarifService.compute (Node) et TarifService
// (Dart) — voir test/officialTariff.test.js et tool/tarif_parity_check.dart.
// Aucun appel réseau (donc aucune dépense Google Maps) : un service
// d'itinéraire éventuel est injecté via `trustedRouteKm`.

const crypto = require('crypto');
const { DEFAULT_TARIFF_CONFIG } = require('./tariffConfig');

const EARTH_RADIUS_KM = 6371.0;
const rad = (d) => (d * Math.PI) / 180;

function haversineKm(lat1, lng1, lat2, lng2) {
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function validPoint(p) {
  return !!p && typeof p.lat === 'number' && typeof p.lng === 'number'
    && Number.isFinite(p.lat) && Number.isFinite(p.lng)
    && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180
    && !(p.lat === 0 && p.lng === 0); // (0,0) = coordonnée « vide » des anciennes apps
}

// Même arrondi que Dart `((raw + 24) ~/ 50) * 50` (valeurs positives).
function roundTo(value, step) {
  const raw = Math.round(value);
  return Math.floor((raw + (step / 2 - 1)) / step) * step;
}

// Heure locale de la ville à partir de l'horloge SERVEUR (UTC arithmétique : indépendant du fuseau de la machine).
function localHour(nowMs, offsetMinutes) {
  return new Date(nowMs + offsetMinutes * 60000).getUTCHours();
}

function isNight(hour, hours) {
  return hour >= hours.nightStartHour || hour < hours.nightEndHour;
}

// Ville de service : la plus proche du point de départ (à défaut, de la destination)
// parmi celles dont le plafond de service (maxServiceKm) n'est pas dépassé.
function resolveCity(config, pickup, destination) {
  const ref = validPoint(pickup) ? pickup : destination;
  let best = null;
  for (const [id, city] of Object.entries(config.cities)) {
    const d = haversineKm(city.center.lat, city.center.lng, ref.lat, ref.lng);
    if (city.maxServiceKm !== null && d > city.maxServiceKm) continue;
    if (!best || d < best.d) best = { id, city, d };
  }
  return best;
}

// Distance retenue pour la zone hors centre. Jamais inférieure au vol d'oiseau (anti-falsification),
// jamais supérieure à vol d'oiseau × maxRoadFactor (anti-aberration). Source de confiance prioritaire.
function resolveDistance({ hav, declaredKm, trustedRouteKm, maxRoadFactor }) {
  const cap = hav * maxRoadFactor;
  const clamp = (v) => Math.min(Math.max(v, hav), cap);
  if (Number.isFinite(trustedRouteKm) && trustedRouteKm > 0) return { km: clamp(trustedRouteKm), source: 'trusted_route' };
  if (Number.isFinite(declaredKm) && declaredKm > 0) {
    const km = clamp(declaredKm);
    return { km, source: km === declaredKm ? 'declared_accepted' : 'declared_clamped' };
  }
  return { km: hav, source: 'haversine' };
}

function scaleAt({ city, hour, mode, distanceInfo, hav }) {
  const night = isNight(hour, city.hours);
  const zone = city.zones.find((z) => hav <= z.maxKm);
  if (zone) {
    return { zoneId: zone.id, isNight: night, isOutside: false, standard: zone.standard[night ? 'night' : 'day'], express: zone.express[night ? 'night' : 'day'], distanceKm: hav, distanceSource: 'zone' };
  }
  const o = city.outside;
  const std = roundTo(o.baseFcfa + distanceInfo.km * o.perKmFcfa, o.roundTo);
  const exp = roundTo(std * o.expressMultiplier, o.roundTo);
  return { zoneId: 'outside', isNight: night, isOutside: true, standard: std, express: exp, distanceKm: distanceInfo.km, distanceSource: distanceInfo.source };
}

const refuse = (code, message) => ({ ok: false, code, message });

// computeOfficialTariff({ serviceType, mode, pickup, destination, nowMs,
//                         declaredDistanceKm?, trustedRouteKm?, config? })
// -> { ok:true, amount, deliveryFee, floorAmount, ... } | { ok:false, code, message }
function computeOfficialTariff(input) {
  const { serviceType, mode = 'standard', pickup, destination, nowMs = Date.now(),
    declaredDistanceKm, trustedRouteKm, config = DEFAULT_TARIFF_CONFIG } = input || {};

  const service = config.services[serviceType];
  if (!service) return refuse('UNKNOWN_SERVICE', 'Service inconnu');
  if (mode !== 'standard' && mode !== 'express') return refuse('INVALID_MODE', 'Mode de livraison invalide');
  if (!Number.isFinite(nowMs)) return refuse('INVALID_TIME', 'Heure serveur invalide');
  if (!validPoint(destination)) return refuse('INVALID_COORDINATES', 'Coordonnées de destination invalides');
  if (pickup !== undefined && pickup !== null && !validPoint(pickup)) return refuse('INVALID_COORDINATES', 'Coordonnées de départ invalides');

  const found = resolveCity(config, pickup, destination);
  if (!found) return refuse('OUT_OF_SERVICE_AREA', 'Zone non desservie');
  const { id: cityId, city } = found;

  const hour = localHour(nowMs, city.timezoneOffsetMinutes);
  const havOf = (pt) => haversineKm(city.center.lat, city.center.lng, pt.lat, pt.lng);
  const havDest = havOf(destination);
  const hav = config.distance.basis === 'farther_point' && validPoint(pickup) ? Math.max(havDest, havOf(pickup)) : havDest;
  if (city.maxServiceKm !== null && hav > city.maxServiceKm) return refuse('OUT_OF_SERVICE_AREA', 'Zone non desservie');

  const maxRoadFactor = config.distance.maxRoadFactor;
  const distanceInfo = resolveDistance({ hav, declaredKm: declaredDistanceKm, trustedRouteKm, maxRoadFactor });
  const lateNight = hour >= city.hours.lateNightStartHour;
  const inside = city.zones.some((z) => hav <= z.maxKm);
  if (!inside && lateNight && distanceInfo.km > city.hours.lateNightMaxKm) {
    return refuse('LATE_NIGHT_RESTRICTED', `Livraison non disponible après ${city.hours.lateNightStartHour}h00 pour les zones à plus de ${city.hours.lateNightMaxKm} km`);
  }

  const scale = scaleAt({ city, hour, mode, distanceInfo, hav });
  // Plancher = prix au vol d'oiseau : aucune distance déclarée honnête ne peut le dépasser par le bas.
  const floorScale = scaleAt({ city, hour, mode, distanceInfo: { km: hav, source: 'haversine' }, hav });
  const scaleFee = (s) => (mode === 'express' ? s.express : s.standard);

  const warnings = [];
  if (service.review) warnings.push('SERVICE_PRICE_UNCONFIRMED');
  if (distanceInfo.source === 'declared_clamped') warnings.push('DECLARED_DISTANCE_ADJUSTED');
  const fee = service.delivery === 'flat' ? service.flatFeeFcfa : scaleFee(scale);
  const floor = service.delivery === 'flat' ? service.flatFeeFcfa : scaleFee(floorScale);
  const gap = service.delivery === 'flat' ? 0 : scaleFee(roundedAt(city, hour, hav * maxRoadFactor, hav, mode)) - floor;

  return {
    ok: true,
    amount: fee,
    deliveryFee: fee,
    floorAmount: floor,
    standardPrice: service.delivery === 'flat' ? service.flatFeeFcfa : scale.standard,
    expressPrice: service.delivery === 'flat' ? service.flatFeeFcfa : scale.express,
    mode,
    serviceType,
    itemsPolicy: service.items,
    cityId,
    zoneId: scale.zoneId,
    isNight: scale.isNight,
    isOutside: scale.isOutside,
    distanceKm: Math.round(scale.distanceKm * 1000) / 1000,
    serverDistanceKm: Math.round(hav * 1000) / 1000,
    distanceSource: scale.distanceSource,
    // Un service d'itinéraire n'a d'intérêt que si le prix peut varier sensiblement entre plancher et plafond.
    routeCheckUseful: scale.isOutside && gap >= config.distance.routeCheckMinGapFcfa && scale.distanceSource !== 'trusted_route',
    tariffVersion: config.version,
    warnings,
  };
}

function roundedAt(city, hour, km, hav, mode) {
  return scaleAt({ city, hour, mode, distanceInfo: { km, source: 'cap' }, hav });
}

// Évalue une commande créée par une ancienne application (sans devis) : jamais de refus ici,
// seulement un verdict utilisable par l'observation (phase 0) puis la correction (phase 2).
// Plancher = minimum sur ±10 min autour de l'heure de création (horloge téléphone ≠ serveur).
const BOUNDARY_WINDOW_MS = 10 * 60 * 1000;
const SERVICE_BY_ORDER_TYPE = Object.freeze({ shopping: 'courses', livraison: 'livraison' });

function assessLegacyOrder({ order, nowMs = Date.now(), config = DEFAULT_TARIFF_CONFIG }) {
  const serviceType = SERVICE_BY_ORDER_TYPE[order && order.type];
  if (!serviceType) return { verdict: 'not_assessed', reason: 'type' };
  const budget = Number(order.budget);
  const destination = { lat: Number(order.destLat), lng: Number(order.destLng) };
  if (!Number.isFinite(budget) || !validPoint(destination)) return { verdict: 'not_assessed', reason: 'data' };
  const pickup = { lat: Number(order.latitude ?? order.deliveryLatitude), lng: Number(order.longitude ?? order.deliveryLongitude) };
  const created = nowMs;
  const mode = order.deliveryMode === 'express' ? 'express' : 'standard';
  const samples = [created - BOUNDARY_WINDOW_MS, created, created + BOUNDARY_WINDOW_MS]
    .map((t) => computeOfficialTariff({ serviceType, mode, pickup: validPoint(pickup) ? pickup : undefined, destination, nowMs: t, config }))
    .filter((r) => r.ok);
  if (!samples.length) return { verdict: 'not_assessed', reason: 'restricted' };
  const floor = Math.min(...samples.map((r) => r.floorAmount));
  return budget < floor
    ? { verdict: 'below_floor', budget, floor, expected: samples[Math.floor(samples.length / 2)].amount }
    : { verdict: 'ok', budget, floor };
}

// Clé de cache d'itinéraire (grille ≈ 110 m, non orientée) : prête pour un futur fournisseur d'itinéraire.
function routeCacheKey(a, b) {
  const g = (p) => `${p.lat.toFixed(3)},${p.lng.toFixed(3)}`;
  const [x, y] = [g(a), g(b)].sort();
  return crypto.createHash('sha1').update(`${x}|${y}`).digest('hex');
}

module.exports = { computeOfficialTariff, assessLegacyOrder, routeCacheKey, haversineKm, validPoint, resolveCity, localHour };
