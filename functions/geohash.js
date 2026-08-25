'use strict';

// Encodage/décodage geohash minimal, autonome (aucune dépendance npm ajoutée
// pour ça — l'algorithme est un standard public bien connu, ~40 lignes).
// Utilisé par le module Immobilier (Master Prompt "GPS privé V2") pour :
//  - `exactGeohash` (précision 9 ≈ ±2,4 m) dans `real_estate_private_locations` ;
//  - l'approximation "position approximative" (troncature à 5 caractères
//    ≈ ±2,4 km × 4,9 km, puis décodage du centre de cette cellule — voir
//    `approximateCoordinates()` ci-dessous).
const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/**
 * Encode une coordonnée en geohash base32.
 * @param {number} latitude entre -90 et 90
 * @param {number} longitude entre -180 et 180
 * @param {number} precision nombre de caractères du geohash (défaut 9)
 */
function encodeGeohash(latitude, longitude, precision = 9) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    throw new Error('Coordonnées invalides pour le geohash.');
  }
  let latRange = [-90, 90];
  let lngRange = [-180, 180];
  let isLon = true;
  let bit = 0;
  let ch = 0;
  let geohash = '';
  while (geohash.length < precision) {
    if (isLon) {
      const mid = (lngRange[0] + lngRange[1]) / 2;
      if (longitude >= mid) {
        ch |= (1 << (4 - bit));
        lngRange[0] = mid;
      } else {
        lngRange[1] = mid;
      }
    } else {
      const mid = (latRange[0] + latRange[1]) / 2;
      if (latitude >= mid) {
        ch |= (1 << (4 - bit));
        latRange[0] = mid;
      } else {
        latRange[1] = mid;
      }
    }
    isLon = !isLon;
    if (bit < 4) {
      bit++;
    } else {
      geohash += BASE32[ch];
      bit = 0;
      ch = 0;
    }
  }
  return geohash;
}

/**
 * Décode un geohash vers le CENTRE de la cellule qu'il représente — jamais
 * le point exact d'origine si le geohash a été tronqué (moins de caractères
 * que la précision d'encodage d'origine), ce qui est exactement le mécanisme
 * utilisé pour produire une position approximative déterministe.
 */
function decodeGeohash(geohash) {
  if (typeof geohash !== 'string' || geohash.length === 0) {
    throw new Error('Geohash invalide.');
  }
  let latRange = [-90, 90];
  let lngRange = [-180, 180];
  let isLon = true;
  for (const c of geohash.toLowerCase()) {
    const idx = BASE32.indexOf(c);
    if (idx === -1) throw new Error(`Caractère geohash invalide: "${c}".`);
    for (let n = 4; n >= 0; n--) {
      const bitN = (idx >> n) & 1;
      if (isLon) {
        const mid = (lngRange[0] + lngRange[1]) / 2;
        if (bitN === 1) lngRange[0] = mid; else lngRange[1] = mid;
      } else {
        const mid = (latRange[0] + latRange[1]) / 2;
        if (bitN === 1) latRange[0] = mid; else latRange[1] = mid;
      }
      isLon = !isLon;
    }
  }
  return {
    latitude: (latRange[0] + latRange[1]) / 2,
    longitude: (lngRange[0] + lngRange[1]) / 2,
  };
}

// Précision volontairement documentée plutôt que supposée (table standard
// geohash — cellules approximatives par nombre de caractères) :
//   5 caractères ≈ ±2,4 km × 4,9 km ("quartier/zone", jamais la maison exacte)
//   9 caractères ≈ ±2,4 m (précision "exacte", usage privé uniquement)
const APPROXIMATE_PRECISION = 5;
const EXACT_PRECISION = 9;

/**
 * Coarsening déterministe : même coordonnée exacte en entrée -> toujours la
 * même position approximative en sortie (jamais un flou aléatoire changeant
 * à chaque lecture). Ce n'est PAS une anonymisation — deux points proches
 * peuvent retomber sur la même cellule, mais un attaquant qui connaît déjà
 * le quartier n'apprend rien de nouveau d'utile pour localiser la maison
 * exacte. Documenté honnêtement, jamais présenté comme une garantie de vie
 * privée forte.
 */
function approximateCoordinates(latitude, longitude, precision = APPROXIMATE_PRECISION) {
  const truncated = encodeGeohash(latitude, longitude, EXACT_PRECISION).slice(0, precision);
  const center = decodeGeohash(truncated);
  return { ...center, geohash: truncated };
}

module.exports = {
  encodeGeohash,
  decodeGeohash,
  approximateCoordinates,
  APPROXIMATE_PRECISION,
  EXACT_PRECISION,
  GEOHASH_BASE32: BASE32,
};
