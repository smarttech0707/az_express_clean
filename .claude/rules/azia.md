---
paths:
  - functions/azia/**
  - functions/test/azia*.test.js
  - lib/screens/ai/**
  - lib/services/az_ia_service.dart
  - lib/providers/az_ia_provider.dart
  - lib/services/voice/**
---

# AZ IA — invariants d'implémentation

Références : `docs/claude/INDEX.md` (prompts 31-33, 113-119, 127), `docs/claude/history/sections/05-az-ia-regles-non-negociables.md`.

## Serveur (`functions/azia/`)
- Boucle d'appel Claude avec tool-calling (plafond 6 tours), `toolRegistry.js` (outils par domaine dans `tools/`), `claudeClient.js` (`SYSTEM_PROMPT` français, bloc statique mis en cache), `contextBuilder.js` (contexte utilisateur injecté, non mis en cache).
- Tout outil d'écriture ou financier : le `handler` crée un `ai_pending_actions` ; l'exécution réelle se fait dans `confirmHandler` via `aiConfirmAction` (confirmation explicite, expiration, anti-replay). `aiConfirmAction` n'est pas un outil : Claude ne peut jamais l'appeler.
- Outils non financiers sans confirmation : mémoire (`remember_user_info`, `remember_named_address`), `create_reminder`, `create_support_ticket`, lectures.
- Les `confirmHandler` reproduisent le comportement sécurisé du chemin Flutter (annulation = `cancelOrderTx` partagé, prix = `tarifService.js`). Ne jamais laisser Claude fournir un montant de livraison. E-Kbine : `fee: 0`.
- Réponse structurée : `buildTurnResponse` / `buildConfirmResponse` (`responseBuilder.js`) ; le type est déterminé par l'outil réellement exécuté, jamais par des mots-clés. `reply` (texte) reste inchangé, `response` est additif.
- Observabilité : `request_logs` (outils utilisés, tours, tokens, durée). Mémoire utilisateur `ai_user_memory`, historique `ai_conversations` (effaçable via `clearAiHistory`).

## Client (`lib/screens/ai/`, `lib/services/voice/`)
- Carte persistante `_PendingActionCard` : écoute `ai_pending_actions` (2 filtres d'égalité, sans `orderBy` → pas d'index) ; boutons Confirmer/Annuler appellent `aiConfirmAction`.
- Rendu des réponses : `buildResponseCard(response)` selon `response.type` uniquement (zéro heuristique de mot-clé).
- Voix : `speech_to_text` → pipeline `VoiceTextProcessor` (nettoyage + dictionnaire métier ; correction floue = confirmation, jamais envoi silencieux) → même contrat `azIaChat`. TTS via `VoiceManager` (niveau 1 Android gratuit ; fournisseurs payants non activés, jamais de clé côté client).
- Hors ligne : `AzIaOfflineEngine` répond localement à quelques questions simples.
- Jamais de message d'exception brut affiché à l'utilisateur.
