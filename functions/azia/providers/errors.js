'use strict';

// Erreur typée levée quand un provider est appelé sans que sa clé API ne soit
// configurée dans functions/.env — distincte d'une vraie erreur réseau/API,
// pour que AIProviderService puisse silencieusement sauter ce provider lors
// d'un fallback plutôt que de le compter comme une panne réelle.
class ProviderNotConfiguredError extends Error {
  constructor(providerName) {
    super(`Le fournisseur IA "${providerName}" n'a pas de clé API configurée (functions/.env)`);
    this.name = 'ProviderNotConfiguredError';
    this.code = 'provider_not_configured';
    this.provider = providerName;
  }
}

module.exports = { ProviderNotConfiguredError };
