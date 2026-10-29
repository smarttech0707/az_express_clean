'use strict';

// Fournisseur d'IA SIMULÉ pour les émulateurs (jamais chargé en production : seul le dossier d'exécution
// test-env/runtime l'embarque). Remplace uniquement le transport réseau d'Anthropic : tout le reste du chemin
// azIaChat (consentement, contexte, outils, historique canonique) est le vrai code.
//
// Chaque requête « envoyée au fournisseur » est journalisée dans ai-sim.log (JSON, une ligne par appel) pour
// prouver ce qui serait transmis. Aucune donnée ne quitte la machine.

const fs = require('fs');
const path = require('path');

const LOG = path.join(__dirname, 'ai-sim.log');
const lastUserText = (messages) => {
  const last = [...messages].reverse().find((m) => m.role === 'user');
  if (!last) return { text: '', hasToolResult: false };
  const blocks = Array.isArray(last.content) ? last.content : [{ type: 'text', text: String(last.content) }];
  return {
    text: blocks.filter((b) => b.type === 'text').map((b) => b.text).join(' ').toLowerCase(),
    hasToolResult: blocks.some((b) => b.type === 'tool_result'),
  };
};

function script(messages) {
  const { text, hasToolResult } = lastUserText(messages);
  if (hasToolResult) return { text: 'Réponse simulée : voici les informations demandées.' };
  if (text.includes('commande')) return { tool: 'track_order', input: {} };
  if (text.includes('solde') || text.includes('portefeuille')) return { tool: 'get_wallet_balance', input: {} };
  if (text.includes('chez moi') || text.includes('adresse')) return { tool: 'get_user_context', input: { fields: ['addresses'] } };
  if (text.includes('près de moi') || text.includes('gps')) return { tool: 'get_user_context', input: { fields: ['location'] } };
  return { text: 'Réponse simulée (question générale).' };
}

function install() {
  const ClaudeProvider = require('./azia/providers/ClaudeProvider');
  let n = 0;
  ClaudeProvider.prototype._getClient = function simulatedClient() {
    return { messages: { create: async (body) => {
      fs.appendFileSync(LOG, `${JSON.stringify({ at: new Date().toISOString(), provider: 'claude-simulated', body })}\n`);
      const step = script(body.messages || []);
      const content = step.tool
        ? [{ type: 'tool_use', id: `sim-${++n}`, name: step.tool, input: step.input }]
        : [{ type: 'text', text: step.text }];
      return { content, stop_reason: step.tool ? 'tool_use' : 'end_turn', usage: { input_tokens: 1, output_tokens: 1 } };
    } } };
  };
}

module.exports = { install, LOG };
