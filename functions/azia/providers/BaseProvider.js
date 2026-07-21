'use strict';

// ═══════════════════════════════════════════════════════════════════════════
// Contrat commun à tous les fournisseurs IA (Master Prompt 108).
//
// Chaque provider implémente :
//   - isConfigured() : bool — sa clé API est-elle présente dans functions/.env ?
//   - generateText(prompt, opts)               → { text, model, inputTokens, outputTokens }
//   - generateChat(messages, opts)              → { text, model, inputTokens, outputTokens }
//   - generateVision(prompt, imageBase64, opts) → { text, model, inputTokens, outputTokens }
//     (lève une erreur explicite si le provider ne supporte pas la vision,
//      plutôt que d'échouer silencieusement)
//
// `messages` : [{ role: 'user'|'assistant', content: string }]
// `opts`     : { model?, temperature?, maxTokens?, system?, mediaType? }
//
// Ce contrat couvre uniquement génération de texte/chat/vision simple — pas
// l'appel d'outils (tool-calling), qui reste spécifique à Claude aujourd'hui
// (seul fournisseur réellement câblé aux outils AZ IA existants). Voir
// AIProviderService.js pour la justification de cette limite volontaire.
// ═══════════════════════════════════════════════════════════════════════════
class BaseProvider {
  constructor(name) {
    if (new.target === BaseProvider) {
      throw new Error('BaseProvider est abstraite, utiliser une sous-classe');
    }
    this.name = name;
  }

  isConfigured() {
    throw new Error(`${this.name}.isConfigured() non implémenté`);
  }

  async generateText(_prompt, _opts) {
    throw new Error(`${this.name}.generateText() non implémenté`);
  }

  async generateChat(_messages, _opts) {
    throw new Error(`${this.name}.generateChat() non implémenté`);
  }

  async generateVision(_prompt, _imageBase64, _opts) {
    throw new Error(`${this.name} ne supporte pas generateVision()`);
  }
}

module.exports = BaseProvider;
