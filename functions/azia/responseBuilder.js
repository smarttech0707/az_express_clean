'use strict';

// ═══════════════════════════════════════════════════════════════════════════
// Réponses structurées AZ IA (Master Prompt 117) — remplace les heuristiques
// visuelles côté Flutter (mots-clés devinés dans le texte de Claude) par une
// enveloppe {type, title, message, icon, color, priority, actions, payload}
// construite ICI, côté serveur, à partir de DONNÉES RÉELLES : le nom de
// l'outil effectivement exécuté ce tour et le résultat RÉEL qu'il a renvoyé
// (jamais un texte re-parsé). Le champ `message` reste le texte de Claude
// (`finalText`), inchangé — la compatibilité descendante est garantie en
// ajoutant ce champ `response` À CÔTÉ du `reply` déjà existant, jamais à sa
// place (voir functions/azia/index.js).
// ═══════════════════════════════════════════════════════════════════════════

const TYPE_META = {
  wallet:              { title: 'Wallet',              icon: 'account_balance_wallet', color: '#1E88E5', priority: 'normal' },
  wallet_history:      { title: 'Historique wallet',   icon: 'history',                color: '#1E88E5', priority: 'normal' },
  wallet_recharge:     { title: 'Recharge wallet',     icon: 'add_card',               color: '#1E88E5', priority: 'normal' },
  wallet_withdrawal:   { title: 'Retrait wallet',      icon: 'money_off',              color: '#1E88E5', priority: 'normal' },
  delivery:            { title: 'Livraison',            icon: 'local_shipping',         color: '#EF6C00', priority: 'normal' },
  delivery_tracking:   { title: 'Suivi de livraison',  icon: 'local_shipping',         color: '#EF6C00', priority: 'normal' },
  delivery_cancel:     { title: 'Livraison annulée',   icon: 'cancel',                 color: '#E53935', priority: 'normal' },
  driver:              { title: 'Livreur',              icon: 'sports_motorsports',     color: '#EF6C00', priority: 'normal' },
  restaurant:          { title: 'Restaurant',           icon: 'restaurant',             color: '#D84315', priority: 'normal' },
  restaurant_order:    { title: 'Commande restaurant',  icon: 'restaurant_menu',        color: '#D84315', priority: 'normal' },
  restaurant_status:   { title: 'Statut restaurant',    icon: 'storefront',             color: '#D84315', priority: 'normal' },
  marketplace:         { title: 'Marketplace',          icon: 'storefront',             color: '#2E7D32', priority: 'normal' },
  marketplace_product: { title: 'Produit',              icon: 'shopping_bag',           color: '#2E7D32', priority: 'normal' },
  marketplace_chat:    { title: 'Message vendeur',      icon: 'chat',                   color: '#2E7D32', priority: 'normal' },
  ekbine:              { title: 'E-Kbine',              icon: 'swap_horiz',             color: '#3949AB', priority: 'normal' },
  ekbine_order:        { title: 'Commande E-Kbine',     icon: 'swap_horiz',             color: '#3949AB', priority: 'normal' },
  ekbine_tracking:     { title: 'Suivi E-Kbine',        icon: 'swap_horiz',             color: '#3949AB', priority: 'normal' },
  pharmacy:            { title: 'Pharmacie',            icon: 'medication',             color: '#00897B', priority: 'normal' },
  bakery:              { title: 'Boulangerie',          icon: 'bakery_dining',          color: '#8D6E63', priority: 'normal' },
  real_estate:         { title: 'Immobilier',           icon: 'home_work',              color: '#6A1B9A', priority: 'normal' },
  visit_request:       { title: 'Demande de visite',    icon: 'event_available',        color: '#6A1B9A', priority: 'normal' },
  support:             { title: 'Support',               icon: 'support_agent',          color: '#546E7A', priority: 'normal' },
  help:                { title: 'Aide',                  icon: 'help_outline',           color: '#546E7A', priority: 'normal' },
  faq:                 { title: 'Question fréquente',   icon: 'quiz',                   color: '#546E7A', priority: 'normal' },
  error:               { title: 'Erreur',                icon: 'error_outline',          color: '#E53935', priority: 'high' },
  warning:             { title: 'Attention',             icon: 'warning_amber',          color: '#F9A825', priority: 'high' },
  success:             { title: 'Succès',                icon: 'check_circle',           color: '#2E7D32', priority: 'normal' },
  confirmation:        { title: 'Confirmation requise',  icon: 'shield',                 color: '#EF6C00', priority: 'high' },
  notification:        { title: 'Notification',          icon: 'notifications',          color: '#546E7A', priority: 'normal' },
  payment:             { title: 'Paiement',              icon: 'payments',               color: '#1E88E5', priority: 'normal' },
  location:            { title: 'Position',              icon: 'location_on',            color: '#EF6C00', priority: 'low' },
  weather:             { title: 'Météo',                 icon: 'wb_sunny',               color: '#FB8C00', priority: 'low' },
  generic:             { title: 'AZ IA',                 icon: 'auto_awesome',           color: '#6D4C41', priority: 'normal' },
};

const ALL_TYPES = Object.keys(TYPE_META);

// Outil réellement exécuté -> type, quand le tour se termine SANS
// confirmation en attente (résultat direct, déjà définitif).
const TOOL_TYPE_MAP = {
  track_order:              'delivery_tracking',
  get_wallet_balance:       'wallet',
  get_wallet_transactions:  'wallet_history',
  search_marketplace:       'marketplace',
  search_restaurants:       'restaurant',
  search_pharmacies:        'pharmacy',
  search_real_estate:       'real_estate',
  track_ekbine_order:       'ekbine_tracking',
  create_support_ticket:    'support',
};

// Outil réellement CONFIRMÉ (aiConfirmAction, après confirmHandler+afterConfirm)
// -> type. Distinct de TOOL_TYPE_MAP : la sémantique change une fois l'action
// réellement exécutée plutôt qu'encore en attente. Deux outils (marketplace,
// pharmacie) n'ont pas de type dédié dans l'énumération fournie — mappés sur
// `payment`, le plus proche sémantiquement (un paiement vient d'aboutir),
// documenté explicitement plutôt qu'un type inventé hors énumération.
const CONFIRMED_TOOL_TYPE_MAP = {
  initiate_wallet_recharge: 'wallet_recharge',
  create_delivery_order:    'delivery',
  create_shopping_order:    'delivery',
  cancel_order:             'delivery_cancel',
  create_restaurant_order:  'restaurant_order',
  create_pharmacie_order:   'payment',
  create_marketplace_order: 'payment',
  create_ekbine_order:      'ekbine_order',
  request_property_visit:   'visit_request',
};

// Suggestions rapides déclarées côté serveur (remplace les puces devinées
// côté Flutter au Prompt 116) — texte canné envoyé tel quel si l'utilisateur
// tape dessus, jamais une action qui mute quoi que ce soit directement.
const ACTIONS_BY_TYPE = {
  delivery_tracking: [{ label: 'Suivre la commande', message: 'Où en est ma commande ?' }, { label: 'Annuler', message: 'Annule cette commande.' }],
  delivery:           [{ label: 'Suivre la commande', message: 'Où en est ma commande ?' }],
  delivery_cancel:    [{ label: 'Recommencer', message: "On recommence, j'ai changé d'avis." }],
  ekbine_tracking:    [{ label: 'Suivre la commande', message: 'Où en est ma commande E-Kbine ?' }],
  ekbine_order:       [{ label: 'Suivre la commande', message: 'Où en est ma commande E-Kbine ?' }],
  wallet:             [{ label: 'Recharger', message: 'Je veux recharger mon wallet.' }, { label: 'Historique', message: 'Montre mon historique wallet.' }],
  restaurant:         [{ label: 'Commander', message: 'Je veux commander ici.' }],
  marketplace:        [{ label: 'En savoir plus', message: 'Donne-moi plus de détails.' }],
  real_estate:        [{ label: 'Demander une visite', message: 'Je veux visiter ce bien.' }],
  error:              [{ label: 'Recommencer', message: "On recommence, j'ai changé d'avis." }],
  generic:            [{ label: 'Continuer', message: 'Continue.' }, { label: 'En savoir plus', message: 'Donne-moi plus de détails.' }],
};

function actionsFor(type) {
  return ACTIONS_BY_TYPE[type] || [];
}

function buildEnvelope({ type, message, payload }) {
  const safeType = ALL_TYPES.includes(type) ? type : 'generic';
  const meta = TYPE_META[safeType];
  return {
    type:     safeType,
    title:    meta.title,
    message:  message || '',
    icon:     meta.icon,
    color:    meta.color,
    priority: meta.priority,
    actions:  actionsFor(safeType),
    payload:  payload || {},
  };
}

// Payload pour un résultat d'outil de LECTURE (pas de confirmation en jeu) —
// uniquement des champs réellement présents dans le résultat réel de
// l'outil, jamais une valeur devinée/interpolée.
function buildReadPayload(name, result) {
  if (!result) return {};
  switch (name) {
    case 'get_wallet_balance':
      return { balance: result.balanceFcfa ?? null, currency: 'FCFA' };
    case 'get_wallet_transactions':
      return { transactions: result.transactions || [] };
    case 'track_order': {
      const order = (result.orders || [])[0] || null;
      return {
        orders: result.orders || [],
        ...(order ? {
          orderId: order.id, status: order.status, description: order.description,
          amount: order.budget, driverId: order.driverId, driver: order.driverName || null,
        } : {}),
      };
    }
    case 'track_ekbine_order': {
      const order = (result.orders || [])[0] || null;
      return {
        orders: result.orders || [],
        agent:  result.agentContact || null,
        ...(order ? { orderId: order.id, status: order.status, amount: order.amount } : {}),
      };
    }
    case 'search_marketplace':
    case 'search_restaurants':
    case 'search_pharmacies':
    case 'search_real_estate':
      return { count: result.count ?? (result.results || []).length, results: result.results || [] };
    case 'create_support_ticket':
      return { ticketId: result.ticketId || null };
    default:
      return {};
  }
}

// Payload pour une action réellement CONFIRMÉE — mêmes principes, à partir
// du résultat réel de confirmHandler/afterConfirm fusionnés.
function buildConfirmedPayload(name, result) {
  if (!result) return {};
  switch (name) {
    case 'initiate_wallet_recharge':
      return { txId: result.txId || null, paymentUrl: result.paymentUrl || null };
    case 'create_delivery_order':
    case 'create_shopping_order':
    case 'create_restaurant_order':
    case 'create_marketplace_order':
    case 'create_pharmacie_order':
      return { orderId: result.orderId || null, dispatched: result.dispatched ?? null };
    case 'cancel_order':
      return { orderId: result.orderId || null, refundAmount: result.refundAmount ?? null, commissionRefund: result.commissionRefund ?? null };
    case 'create_ekbine_order':
      return { orderId: result.orderId || null };
    case 'request_property_visit':
      return { requestId: result.requestId || null, agentId: result.agentId || null };
    default:
      return {};
  }
}

// ── azIaChat : une seule enveloppe pour la fin du tour de conversation.
// `toolCalls` = [{name, input, result}] dans l'ordre réel d'exécution.
// `pendingActionAmount` = montant relu depuis `ai_pending_actions/{actionId}`
// juste après création (source de vérité pour `amount`, que tous les
// handlers ne réechoent pas systématiquement dans leur retour immédiat).
function buildTurnResponse({ finalText, toolCalls, pendingActionAmount }) {
  const calls = toolCalls || [];

  // Priorité 1 — une confirmation est en attente : toujours la carte de
  // confirmation, quel que soit l'outil d'origine (garantit que le
  // mécanisme déjà éprouvé de `ai_pending_actions` reste la seule vérité).
  const lastAwaiting = [...calls].reverse().find(c => c.result && c.result.status === 'awaiting_confirmation');
  if (lastAwaiting) {
    return buildEnvelope({
      type: 'confirmation',
      message: finalText,
      payload: {
        actionId: lastAwaiting.result.actionId || null,
        summary:  lastAwaiting.result.summaryFr || null,
        amount:   typeof pendingActionAmount === 'number' ? pendingActionAmount : null,
      },
    });
  }

  // Priorité 2 — un outil a échoué explicitement et rien d'autre n'a réussi.
  const lastError   = [...calls].reverse().find(c => c.result && c.result.error);
  const anySuccess   = calls.some(c => c.result && !c.result.error && c.result.status !== 'awaiting_confirmation');
  if (lastError && !anySuccess) {
    return buildEnvelope({ type: 'error', message: finalText, payload: { reason: lastError.result.error } });
  }

  // Priorité 3 — mapping déterministe par nom du dernier outil VISIBLE
  // réellement exécuté (remember_user_info est un outil silencieux de fond,
  // jamais le déterminant du type affiché).
  const typedCall = [...calls].reverse().find(c => c.name !== 'remember_user_info' && TOOL_TYPE_MAP[c.name]);
  if (typedCall) {
    return buildEnvelope({
      type: TOOL_TYPE_MAP[typedCall.name],
      message: finalText,
      payload: buildReadPayload(typedCall.name, typedCall.result),
    });
  }

  // Aucun outil "typé" exécuté ce tour (échange conversationnel simple, ou
  // uniquement remember_user_info en tâche de fond).
  return buildEnvelope({ type: 'generic', message: finalText, payload: {} });
}

// ── aiConfirmAction : une enveloppe après une confirmation réellement
// exécutée (confirmHandler + afterConfirm déjà passés avec succès).
function buildConfirmResponse({ toolName, result }) {
  const type = CONFIRMED_TOOL_TYPE_MAP[toolName] || 'success';
  const message = (result && (result.message || result.error)) || 'Action confirmée.';
  return buildEnvelope({ type, message, payload: buildConfirmedPayload(toolName, result) });
}

module.exports = { buildTurnResponse, buildConfirmResponse, TYPE_META, ALL_TYPES };
