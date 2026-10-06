'use strict';

const Anthropic = require('@anthropic-ai/sdk');

const MODEL      = 'claude-sonnet-5';
const MAX_TOKENS = 1024;

let _client = null;
function getClient() {
  if (!_client) {
    _client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  }
  return _client;
}

const { SYSTEM_PROMPT } = require('./systemPrompt');

// Forme "content blocks" du system prompt avec un point de cache (prompt
// caching Anthropic) — ce texte est strictement identique à chaque appel
// d'azIaChat, donc coûteux à renvoyer/refacturer en entier à chaque tour.
// Voir aussi toolSchemas dans azia/index.js, qui porte le second point de
// cache (les définitions d'outils sont, elles aussi, statiques).
const SYSTEM_PROMPT_BLOCKS = [
  { type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } },
];

module.exports = { getClient, MODEL, MAX_TOKENS, SYSTEM_PROMPT, SYSTEM_PROMPT_BLOCKS };
