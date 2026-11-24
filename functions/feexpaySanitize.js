'use strict';

/**
 * Expurgation des messages d'erreur FeexPay.
 *
 * Module séparé à dessein : `feexpayPayments.js` est gardé par un test
 * structurel qui interdit tout littéral `Bearer ` / `Authorization` / `axios`
 * (il doit rester un module de décision pur, sans client HTTP ni identifiant).
 * Un sanitizer, par nature, doit nommer ces motifs pour pouvoir les masquer —
 * il vit donc ici, et le garde-fou de l'autre module reste à pleine force
 * plutôt que d'être assoupli.
 *
 * Rien de ce qui sort d'ici ne doit permettre de reconstituer un secret, une
 * URL complète, ni une donnée personnelle.
 */

const PROVIDER_MESSAGE_MAX_LENGTH = 200;

/**
 * Masque : jeton porteur, en-têtes d'autorisation, clés d'API, `wh_secret`,
 * toute URL réduite à son origine, et les numéros de téléphone. Borne ensuite
 * la longueur pour qu'un corps volumineux ne puisse jamais être recopié.
 *
 * Les valeurs vivantes de `FEEXPAY_TOKEN` / `FEEXPAY_WEBHOOK_SECRET` sont
 * retirées en premier par comparaison directe : même si FeexPay renvoyait un
 * jour le secret dans un message, il ne franchirait pas cette fonction.
 */
function sanitizeProviderMessage(message) {
  let safe = String(message == null ? '' : message);
  for (const name of ['FEEXPAY_TOKEN', 'FEEXPAY_WEBHOOK_SECRET']) {
    const live = process.env[name];
    if (live) safe = safe.split(live).join('[REDACTED]');
  }
  safe = safe
    .replace(/Bearer\s+[A-Za-z0-9._\-=]+/gi, 'Bearer [REDACTED]')
    .replace(/(authorization|x-api-key|api[_-]?key)\s*[:=]\s*\S+/gi, '$1: [REDACTED]')
    .replace(/wh_secret=[^&\s"']+/gi, 'wh_secret=[REDACTED]')
    .replace(/(token|secret|password)["'\s]*[:=]["'\s]*[^,"'}\s]+/gi, '$1=[REDACTED]')
    // Un numéro de téléphone est une donnée personnelle : jamais journalisé.
    .replace(/\+?\d{8,15}/g, '[PHONE]')
    // Toute URL est réduite à son origine : une query string peut porter le
    // secret du webhook.
    .replace(/https?:\/\/([^\s/?#"']+)[^\s"']*/gi, 'https://$1/[...]')
    .replace(/\s+/g, ' ')
    .trim();
  return safe.slice(0, PROVIDER_MESSAGE_MAX_LENGTH);
}

module.exports = { PROVIDER_MESSAGE_MAX_LENGTH, sanitizeProviderMessage };
