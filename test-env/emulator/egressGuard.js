'use strict';

// Garde de sortie réseau des Cloud Functions lancées dans l'émulateur.
//
// Chargé AVANT tout code applicatif (voir emulator-entry.js dans le dossier d'exécution). Il coupe toute
// connexion sortante vers autre chose que la machine locale : FeexPay, SMS, API d'IA (Anthropic, OpenAI,
// Gemini…), FCM, Google Cloud… échouent immédiatement, quelle que soit la bibliothèque (axios, https, fetch/undici,
// SDK, http2) car toutes passent par net.Socket.prototype.connect.
//
// N'est jamais chargé en production : seul le dossier d'exécution des émulateurs (test-env/runtime) l'embarque.

const net = require('net');

const ALLOWED_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]', '0.0.0.0', '::']);

function isAllowedHost(host) {
  if (host === undefined || host === null || host === '') return true; // défaut Node = localhost
  return ALLOWED_HOSTS.has(String(host).toLowerCase());
}

class EgressBlockedError extends Error {
  constructor(host, port) {
    super(`AZ_EGRESS_BLOCKED: connexion sortante vers ${host}:${port} interdite dans l'émulateur`);
    this.code = 'AZ_EGRESS_BLOCKED';
  }
}

const blocked = [];

function install() {
  if (net.Socket.prototype.connect.__azEgressGuard) return;
  const original = net.Socket.prototype.connect;
  function guarded(...args) {
    // net.connect() appelle socket.connect([options, cb]) : arguments déjà normalisés dans un tableau.
    // Ne pas les ré-analyser (l'hôte serait perdu et la connexion laissée passer).
    const normalized = Array.isArray(args[0]) ? args[0] : net._normalizeArgs(args);
    const options = normalized[0];
    if (!options || typeof options !== 'object') {
      process.nextTick(() => this.destroy(new EgressBlockedError('inconnu', '?')));
      return this;
    }
    // Socket de domaine Unix / pipe nommé : local par nature.
    if (!options.path && !isAllowedHost(options.host)) {
      const err = new EgressBlockedError(options.host, options.port);
      blocked.push(`${options.host}:${options.port}`);
      console.error(`[egress-guard] ${err.message}`);
      process.nextTick(() => this.destroy(err));
      return this;
    }
    return original.apply(this, args);
  }
  guarded.__azEgressGuard = true;
  net.Socket.prototype.connect = guarded;
}

// Seconde couche : aucune résolution DNS pour un nom externe (n'évite pas la fuite de requête si une
// bibliothèque appelle c-ares directement, mais coupe lookup() qui sert à net/http/https).
const dns = require('dns');
const realLookup = dns.lookup;
function guardedLookup(hostname, ...rest) {
  if (!isAllowedHost(hostname)) {
    const cb = rest.find((r) => typeof r === 'function');
    const err = new EgressBlockedError(hostname, 'dns');
    console.error(`[egress-guard] ${err.message}`);
    if (cb) return process.nextTick(cb, err);
    throw err;
  }
  return realLookup.call(dns, hostname, ...rest);
}
if (!dns.lookup.__azEgressGuard) {
  guardedLookup.__azEgressGuard = true;
  dns.lookup = guardedLookup;
}

install();

module.exports = { isAllowedHost, EgressBlockedError, blockedConnections: () => [...blocked] };
