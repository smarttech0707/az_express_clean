'use strict';

// Proxy Google Maps (Lot 1) — mapsRouteCF, mapsAutocompleteCF, mapsPlaceDetailsCF, mapsGeocodeCF.
//
// POURQUOI : une clé appelée par des requêtes web depuis l'application ne peut pas être restreinte à
// l'application (elle se lit dans l'APK). Ici la clé reste côté serveur (secret GOOGLE_MAPS_SERVER_KEY),
// restreinte aux seules API Routes, Places (New) et Geocoding du projet de production.
//
// Contrat : enveloppe `{success, error, message, data, code}`. Aucune réponse ni aucun journal ne contient
// la clé, l'URL appelée (la clé y figure pour Geocoding) ou le message brut de Google.
// Aucune écriture Firestore en dehors de la limitation de débit.

const SECRET_NAME = 'GOOGLE_MAPS_SERVER_KEY';

const ROUTES_URL = 'https://routes.googleapis.com/directions/v2:computeRoutes';
const AUTOCOMPLETE_URL = 'https://places.googleapis.com/v1/places:autocomplete';
const PLACE_URL = 'https://places.googleapis.com/v1/places/';
const GEOCODE_URL = 'https://maps.googleapis.com/maps/api/geocode/json';

const REGION_CODE = 'ci';
const LANGUAGE = 'fr';
const UPSTREAM_TIMEOUT_MS = 8000;
const MAX_PREDICTIONS = 8;
const MAX_GEOCODE_RESULTS = 3;
const MAX_BIAS_RADIUS_M = 50000; // plafond de l'API Places (New)

// Limites par utilisateur et par minute. L'itinéraire est recalculé tous les 200 m pendant un suivi :
// 40/min laisse une large marge sans permettre d'épuiser le quota Google depuis un seul compte.
const RATE_LIMITS = Object.freeze({
  route: { action: 'maps_route', max: 40, windowSeconds: 60 },
  autocomplete: { action: 'maps_autocomplete', max: 60, windowSeconds: 60 },
  placeDetails: { action: 'maps_place_details', max: 30, windowSeconds: 60 },
  geocode: { action: 'maps_geocode', max: 40, windowSeconds: 60 },
});

const CACHE_TTL_MS = Object.freeze({
  route: 2 * 60 * 1000,
  autocomplete: 60 * 1000,
  placeDetails: 60 * 60 * 1000,
  geocode: 60 * 60 * 1000,
});
const CACHE_MAX_ENTRIES = 500;

const envelope = (success, code, message, data = null) => ({ success, error: success ? null : code, message, data, code });
const refusal = (code, message) => envelope(false, code, message);

const SESSION_TOKEN_RE = /^[A-Za-z0-9_-]{8,64}$/;
const PLACE_ID_RE = /^[A-Za-z0-9_-]{10,255}$/;
const KEY_LIKE_RE = /AIza[0-9A-Za-z_-]{10,}/g;

function validPoint(p) {
  return !!p && typeof p === 'object' &&
    typeof p.lat === 'number' && typeof p.lng === 'number' &&
    Number.isFinite(p.lat) && Number.isFinite(p.lng) &&
    p.lat >= -90 && p.lat <= 90 && p.lng >= -180 && p.lng <= 180 &&
    !(p.lat === 0 && p.lng === 0); // (0,0) = coordonnée non renseignée dans l'application
}

const cleanText = (v, max) => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, max) : '');
const round = (n, decimals) => Number(n.toFixed(decimals));

// "123s" ou "123.4s" (format Duration de l'API Routes) → secondes entières.
function parseDurationSeconds(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.max(0, Math.round(value));
  const m = typeof value === 'string' ? /^(\d+(?:\.\d+)?)s$/.exec(value.trim()) : null;
  return m ? Math.round(Number(m[1])) : null;
}

// Journal sans secret : code HTTP et statut court uniquement, jamais d'URL ni de message brut.
function safeStatus(value) {
  return String(value == null ? '' : value).replace(KEY_LIKE_RE, '[cle]').replace(/[^A-Za-z0-9_ .-]/g, '').slice(0, 40);
}

function createTtlCache({ now, maxEntries = CACHE_MAX_ENTRIES }) {
  const store = new Map();
  return {
    get(key, ttlMs) {
      const hit = store.get(key);
      if (!hit) return undefined;
      if (now() - hit.at > ttlMs) { store.delete(key); return undefined; }
      return hit.value;
    },
    set(key, value) {
      store.delete(key);
      store.set(key, { value, at: now() });
      // Map conserve l'ordre d'insertion : la première clé est la plus ancienne.
      while (store.size > maxEntries) store.delete(store.keys().next().value);
    },
    size: () => store.size,
  };
}

// Requête HTTP par défaut (fetch natif de Node 22). Renvoie { status, json } ; `json` vaut null si illisible.
async function defaultHttpRequest({ url, method = 'GET', headers = {}, body, timeoutMs = UPSTREAM_TIMEOUT_MS }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method, headers, signal: controller.signal,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let json = null;
    try { json = await res.json(); } catch (_) { json = null; }
    return { status: res.status, json };
  } finally {
    clearTimeout(timer);
  }
}

function createMapsProxy({
  getKey,
  httpRequest = defaultHttpRequest,
  now = () => Date.now(),
  log = (line) => console.warn(line),
} = {}) {
  const cache = createTtlCache({ now });

  function readKey() {
    try {
      const key = typeof getKey === 'function' ? getKey() : '';
      const value = typeof key === 'string' ? key.trim() : '';
      // `DISABLED` = valeur factice des émulateurs locaux (test-env/stage-functions.js) : jamais envoyée à Google.
      return value === 'DISABLED' ? '' : value;
    } catch (_) {
      return '';
    }
  }

  // Appel amont commun : aucune exception ne sort, et rien de ce qui est journalisé ne contient la clé.
  async function upstream(op, request) {
    try {
      const res = await httpRequest(request);
      const status = res && Number(res.status);
      if (!res || !Number.isFinite(status)) {
        log(`[mapsProxy] ${op} reponse amont invalide`);
        return { ok: false };
      }
      if (status < 200 || status >= 300) {
        const upstreamStatus = res.json && res.json.error && res.json.error.status;
        log(`[mapsProxy] ${op} amont http=${status} statut=${safeStatus(upstreamStatus)}`);
        return { ok: false };
      }
      return { ok: true, json: res.json || {} };
    } catch (err) {
      log(`[mapsProxy] ${op} amont injoignable type=${safeStatus(err && err.name)}`);
      return { ok: false };
    }
  }

  const notConfigured = () => refusal('MAPS_NOT_CONFIGURED', 'Service de cartographie non configuré');
  const upstreamFailed = () => refusal('UPSTREAM_UNAVAILABLE', 'Service de cartographie momentanément indisponible');

  // ── Itinéraire ────────────────────────────────────────────────────────────
  function validateRoute(data) {
    const d = data || {};
    if (!validPoint(d.origin) || !validPoint(d.destination)) return { error: refusal('INVALID_ARGUMENT', 'Départ ou destination invalide') };
    return { value: { origin: d.origin, destination: d.destination, withTraffic: d.withTraffic === true } };
  }

  async function route(input) {
    const { origin, destination, withTraffic } = input;
    // Clé arrondie à 4 décimales (≈ 11 m) : deux écrans qui suivent le même trajet partagent le résultat.
    const cacheKey = `route|${round(origin.lat, 4)},${round(origin.lng, 4)}|${round(destination.lat, 4)},${round(destination.lng, 4)}`;
    if (!withTraffic) {
      const cached = cache.get(cacheKey, CACHE_TTL_MS.route);
      if (cached) return envelope(true, 'OK', 'Itinéraire calculé', cached);
    }
    const key = readKey();
    if (!key) return notConfigured();
    const point = (p) => ({ location: { latLng: { latitude: p.lat, longitude: p.lng } } });
    const res = await upstream('route', {
      url: ROUTES_URL,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline',
      },
      body: {
        origin: point(origin),
        destination: point(destination),
        travelMode: 'DRIVE',
        routingPreference: withTraffic ? 'TRAFFIC_AWARE' : 'TRAFFIC_UNAWARE',
        languageCode: LANGUAGE,
        regionCode: REGION_CODE,
      },
    });
    if (!res.ok) return upstreamFailed();
    const first = Array.isArray(res.json.routes) ? res.json.routes[0] : null;
    const encodedPolyline = first && first.polyline && first.polyline.encodedPolyline;
    const durationSeconds = first ? parseDurationSeconds(first.duration) : null;
    if (!first || typeof encodedPolyline !== 'string' || !encodedPolyline || durationSeconds === null) {
      return refusal('NO_ROUTE', 'Aucun itinéraire routier trouvé');
    }
    // L'API omet distanceMeters quand la distance est nulle.
    const distanceMeters = Number.isFinite(Number(first.distanceMeters)) ? Math.max(0, Math.round(Number(first.distanceMeters))) : 0;
    // `isEstimate: false` : le client ne doit JAMAIS déduire lui-même qu'un itinéraire est réel.
    const data = { encodedPolyline, distanceMeters, durationSeconds, withTraffic, isEstimate: false };
    if (!withTraffic) cache.set(cacheKey, data);
    return envelope(true, 'OK', 'Itinéraire calculé', data);
  }

  // ── Recherche de lieux ────────────────────────────────────────────────────
  function validateAutocomplete(data) {
    const d = data || {};
    const input = cleanText(d.input, 120);
    if (input.length < 2) return { error: refusal('INVALID_ARGUMENT', 'Recherche trop courte') };
    let bias = null;
    if (d.location !== undefined && d.location !== null) {
      const radius = Number(d.radiusMeters);
      if (!validPoint(d.location) || !Number.isFinite(radius) || radius <= 0) {
        return { error: refusal('INVALID_ARGUMENT', 'Zone de recherche invalide') };
      }
      bias = { lat: d.location.lat, lng: d.location.lng, radiusMeters: Math.min(Math.round(radius), MAX_BIAS_RADIUS_M) };
    }
    let sessionToken = null;
    if (d.sessionToken !== undefined && d.sessionToken !== null) {
      if (typeof d.sessionToken !== 'string' || !SESSION_TOKEN_RE.test(d.sessionToken)) {
        return { error: refusal('INVALID_ARGUMENT', 'Jeton de session invalide') };
      }
      sessionToken = d.sessionToken;
    }
    return { value: { input, bias, sessionToken } };
  }

  async function autocomplete(input) {
    const { input: text, bias, sessionToken } = input;
    const cacheKey = `ac|${text.toLowerCase()}|${bias ? `${round(bias.lat, 2)},${round(bias.lng, 2)},${bias.radiusMeters}` : '-'}`;
    const cached = cache.get(cacheKey, CACHE_TTL_MS.autocomplete);
    if (cached) return envelope(true, 'OK', 'Suggestions', cached);
    const key = readKey();
    if (!key) return notConfigured();
    const body = { input: text, languageCode: LANGUAGE, includedRegionCodes: [REGION_CODE] };
    if (bias) body.locationBias = { circle: { center: { latitude: bias.lat, longitude: bias.lng }, radius: bias.radiusMeters } };
    if (sessionToken) body.sessionToken = sessionToken;
    const res = await upstream('autocomplete', {
      url: AUTOCOMPLETE_URL,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask': 'suggestions.placePrediction.placeId,suggestions.placePrediction.text.text,' +
          'suggestions.placePrediction.structuredFormat.mainText.text,suggestions.placePrediction.structuredFormat.secondaryText.text',
      },
      body,
    });
    if (!res.ok) return upstreamFailed();
    const suggestions = Array.isArray(res.json.suggestions) ? res.json.suggestions : [];
    const predictions = [];
    for (const s of suggestions) {
      const p = s && s.placePrediction;
      if (!p || typeof p.placeId !== 'string' || !p.placeId) continue;
      const description = cleanText(p.text && p.text.text, 300);
      const mainText = cleanText(p.structuredFormat && p.structuredFormat.mainText && p.structuredFormat.mainText.text, 200) || description;
      if (!mainText) continue;
      predictions.push({
        placeId: p.placeId,
        mainText,
        secondaryText: cleanText(p.structuredFormat && p.structuredFormat.secondaryText && p.structuredFormat.secondaryText.text, 200),
        description: description || mainText,
      });
      if (predictions.length >= MAX_PREDICTIONS) break;
    }
    const data = { predictions };
    cache.set(cacheKey, data);
    return envelope(true, 'OK', 'Suggestions', data);
  }

  // ── Coordonnées d'un lieu ─────────────────────────────────────────────────
  function validatePlaceDetails(data) {
    const d = data || {};
    if (typeof d.placeId !== 'string' || !PLACE_ID_RE.test(d.placeId)) return { error: refusal('INVALID_ARGUMENT', 'Identifiant de lieu invalide') };
    let sessionToken = null;
    if (d.sessionToken !== undefined && d.sessionToken !== null) {
      if (typeof d.sessionToken !== 'string' || !SESSION_TOKEN_RE.test(d.sessionToken)) {
        return { error: refusal('INVALID_ARGUMENT', 'Jeton de session invalide') };
      }
      sessionToken = d.sessionToken;
    }
    return { value: { placeId: d.placeId, sessionToken } };
  }

  async function placeDetails(input) {
    const { placeId, sessionToken } = input;
    const cacheKey = `pd|${placeId}`;
    const cached = cache.get(cacheKey, CACHE_TTL_MS.placeDetails);
    if (cached) return envelope(true, 'OK', 'Lieu localisé', cached);
    const key = readKey();
    if (!key) return notConfigured();
    const query = sessionToken ? `?sessionToken=${encodeURIComponent(sessionToken)}` : '';
    const res = await upstream('placeDetails', {
      url: `${PLACE_URL}${encodeURIComponent(placeId)}${query}`,
      method: 'GET',
      headers: { 'X-Goog-Api-Key': key, 'X-Goog-FieldMask': 'id,location,formattedAddress' },
    });
    if (!res.ok) return upstreamFailed();
    const loc = res.json.location;
    const point = loc ? { lat: Number(loc.latitude), lng: Number(loc.longitude) } : null;
    if (!validPoint(point)) return refusal('NOT_FOUND', 'Lieu introuvable');
    const data = { lat: point.lat, lng: point.lng, formattedAddress: cleanText(res.json.formattedAddress, 300) };
    cache.set(cacheKey, data);
    return envelope(true, 'OK', 'Lieu localisé', data);
  }

  // ── Géocodage direct (adresse → point) et inverse (point → adresse) ───────
  function validateGeocode(data) {
    const d = data || {};
    const hasAddress = d.address !== undefined && d.address !== null;
    const hasPoint = d.location !== undefined && d.location !== null;
    if (hasAddress === hasPoint) return { error: refusal('INVALID_ARGUMENT', 'Fournir une adresse OU une position') };
    if (hasAddress) {
      const address = cleanText(d.address, 200);
      if (address.length < 3) return { error: refusal('INVALID_ARGUMENT', 'Adresse trop courte') };
      return { value: { address } };
    }
    if (!validPoint(d.location)) return { error: refusal('INVALID_ARGUMENT', 'Position invalide') };
    return { value: { location: { lat: d.location.lat, lng: d.location.lng } } };
  }

  async function geocode(input) {
    const cacheKey = input.address
      ? `gc|a|${input.address.toLowerCase()}`
      : `gc|p|${round(input.location.lat, 4)},${round(input.location.lng, 4)}`;
    const cached = cache.get(cacheKey, CACHE_TTL_MS.geocode);
    if (cached) return envelope(true, 'OK', 'Géocodage', cached);
    const key = readKey();
    if (!key) return notConfigured();
    const params = new URLSearchParams({ language: LANGUAGE, region: REGION_CODE, key });
    if (input.address) params.set('address', input.address);
    else params.set('latlng', `${input.location.lat},${input.location.lng}`);
    const res = await upstream('geocode', { url: `${GEOCODE_URL}?${params.toString()}`, method: 'GET' });
    if (!res.ok) return upstreamFailed();
    const status = res.json.status;
    if (status !== 'OK' && status !== 'ZERO_RESULTS') {
      // Geocoding répond HTTP 200 même en refus : le statut applicatif fait foi.
      log(`[mapsProxy] geocode statut=${safeStatus(status)}`);
      return upstreamFailed();
    }
    const results = [];
    for (const r of Array.isArray(res.json.results) ? res.json.results : []) {
      const loc = r && r.geometry && r.geometry.location;
      const point = loc ? { lat: Number(loc.lat), lng: Number(loc.lng) } : null;
      if (!validPoint(point)) continue;
      results.push({ lat: point.lat, lng: point.lng, formattedAddress: cleanText(r.formatted_address, 300) });
      if (results.length >= MAX_GEOCODE_RESULTS) break;
    }
    const data = { results };
    cache.set(cacheKey, data);
    return envelope(true, 'OK', 'Géocodage', data);
  }

  return {
    route: { validate: validateRoute, run: route },
    autocomplete: { validate: validateAutocomplete, run: autocomplete },
    placeDetails: { validate: validatePlaceDetails, run: placeDetails },
    geocode: { validate: validateGeocode, run: geocode },
    cacheSize: () => cache.size(),
  };
}

// ── Rôle et statut (Lot 1.2.1) ───────────────────────────────────────────────
// Seuls les comptes `clients` et `livreurs` utilisent le proxy Maps dans
// l'application (vérifié : aucun autre écran/rôle n'appelle MapsProxyClient).
// Lecture SANS cache à chaque appel : un contrôle d'accès de sécurité ne doit
// jamais servir une réponse périmée (une mise en cache, même courte, laisse
// une fenêtre où un compte suspendu resterait autorisé — voir l'audit
// complémentaire du Lot 1.2.1, qui a écarté le cache pour cette raison).
//
// Règle : l'absence des DEUX documents = aucun rôle éligible identifié =
// refus (jamais d'autorisation par défaut pour un compte non vérifié).
// L'absence d'UN SEUL des deux ne refuse pas en soi — l'autre peut être le
// rôle réel de l'appelant (un livreur n'a pas de document `clients`, et
// inversement). Un `isSuspended: true` sur l'UN OU L'AUTRE document existant
// refuse, quel que soit l'état du second.
//
// Une erreur de lecture Firestore (réseau, permission…) N'EST PAS
// interceptée ici : elle se propage telle quelle et devient un code
// `internal` côté client — jamais un accès autorisé par défaut.
async function assertEligibleRole({ db, HttpsError, uid }) {
  const [clientSnap, driverSnap] = await Promise.all([
    db.collection('clients').doc(uid).get(),
    db.collection('livreurs').doc(uid).get(),
  ]);
  if (!clientSnap.exists && !driverSnap.exists) {
    throw new HttpsError('permission-denied', 'Rôle non autorisé pour la cartographie');
  }
  const suspended = (clientSnap.exists && clientSnap.data().isSuspended === true) ||
    (driverSnap.exists && driverSnap.data().isSuspended === true);
  if (suspended) {
    throw new HttpsError('permission-denied', 'Compte suspendu');
  }
}

// Ordre des contrôles : authentification → rôle/statut → validation (aucune E/S) → limitation de débit → cache/Google.
// Le rôle/statut passe avant la validation : un appel refusé pour suspension ne doit même pas faire
// l'effort d'interpréter des paramètres. La validation passe avant la limite pour qu'une requête
// malformée ne consomme ni quota ni écriture.
function buildMapsCallables({ onCall, HttpsError, checkRateLimit, proxy, db }) {
  const make = (name) => onCall(async (request) => {
    if (!request || !request.auth || !request.auth.uid) throw new HttpsError('unauthenticated', 'Vous devez être connecté');
    await assertEligibleRole({ db, HttpsError, uid: request.auth.uid });
    const checked = proxy[name].validate(request.data);
    if (checked.error) return checked.error;
    const limit = RATE_LIMITS[name];
    await checkRateLimit(request.auth.uid, limit.action, limit.max, limit.windowSeconds);
    return proxy[name].run(checked.value);
  });
  return {
    mapsRouteCF: make('route'),
    mapsAutocompleteCF: make('autocomplete'),
    mapsPlaceDetailsCF: make('placeDetails'),
    mapsGeocodeCF: make('geocode'),
  };
}

module.exports = {
  SECRET_NAME,
  RATE_LIMITS,
  CACHE_TTL_MS,
  createMapsProxy,
  buildMapsCallables,
  assertEligibleRole,
  parseDurationSeconds,
  validPoint,
};
