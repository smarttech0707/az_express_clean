# Fournisseur OpenAI pour AZ IA — guide d'activation (Mission 15)

Ce document explique comment activer/désactiver le fournisseur OpenAI ajouté
à `functions/azia/providers/OpenAIProvider.js`, sans jamais toucher à
Flutter ni à la boucle d'outils réelle d'AZ IA (`functions/azia/index.js`,
qui force `forceProvider:'claude'` et n'est pas modifiée par ce chantier).

## 1. Activer OpenAI pour les réponses simples (sans outil)

Dans `functions/.env` (copié depuis `.env.example`) :

```
OPENAI_API_KEY=sk-...           # vraie clé, jamais committée
AI_DEFAULT_PROVIDER=openai      # conversations simples / FAQ / reformulation
```

Claude reste utilisé pour tout ce qui a des outils (voir §5). Aucun
redéploiement de règles Firestore n'est nécessaire — c'est une simple
variable d'environnement Cloud Functions.

## 2. Garder Claude comme fournisseur par défaut (ne rien faire)

Ne pas définir `AI_DEFAULT_PROVIDER` (ou le laisser à `claude`, sa valeur par
défaut) — tout continue de fonctionner exactement comme avant ce chantier.

## 3. Activer OpenAI UNIQUEMENT pour les réponses simples

```
AI_DEFAULT_PROVIDER=openai   # conversation simple / FAQ / support / classification
AI_COMPLEX_PROVIDER=claude   # requêtes complexes (turn.complexity==='complex')
AI_IMAGE_PROVIDER=claude     # analyse d'image, si vous ne voulez pas encore l'y envoyer
AI_TOOL_PROVIDER=claude      # NE JAMAIS CHANGER avant validation E2E (voir §5)
```

Chaque variable a un repli sûr sur `claude` si absente — aucune ne peut faire
basculer un tour à outils vers OpenAI par accident (voir `aiRouter.js`, la
garde `tools_openai_disabled` reroute automatiquement vers Claude si
`AI_TOOL_PROVIDER=openai` était configuré par erreur alors que le tool
calling OpenAI n'est pas activé).

## 4. Désactiver le fallback automatique

```
AI_ENABLE_FALLBACK=false   # défaut — aucune bascule automatique entre fournisseurs
```

Avec `AI_ENABLE_FALLBACK=true`, une panne du fournisseur par défaut (sans
outil) peut basculer vers `AI_FALLBACK_PROVIDERS` (CSV, ex. `claude,gemini`).
**Un tour à outils ne bascule JAMAIS vers un fournisseur qui ne supporte pas
les outils** — `AIProviderService.callWithFallback` filtre l'ordre de
tentative par `provider.supportsTools()`, indépendamment de ce réglage.

## 5. Activer plus tard le tool-calling OpenAI (⚠️ après tests E2E complets)

```
AI_OPENAI_TOOL_CALLING_ENABLED=true   # NE PAS activer avant des tests E2E réels et complets
AI_TOOL_PROVIDER=openai               # ou laisser claude et forcer ponctuellement par appelant
```

Même avec ce flag activé, `functions/azia/index.js` (la vraie boucle
d'outils AZ IA) continue de forcer `forceProvider:'claude'` en dur — pour
qu'OpenAI participe réellement à un tour à outils en production, ce
fichier devra être explicitement modifié un jour, avec sa propre validation
dédiée (hors périmètre de ce chantier). Ce flag ne fait aujourd'hui
qu'ouvrir la porte pour de futurs appelants génériques d'`AIProviderService`.

## 6. Revenir instantanément à Claude (rollback)

Deux façons, ni l'une ni l'autre ne nécessitant de changement de code :

1. **Supprimer/vider `OPENAI_API_KEY`** dans `functions/.env` puis redéployer
   les Cloud Functions concernées — `OpenAIProvider.isConfigured()` renverra
   `false`, il ne sera plus jamais tenté (comportement déjà en place avant ce
   chantier pour tout fournisseur sans clé).
2. **Remettre `AI_DEFAULT_PROVIDER=claude`** (ou simplement retirer la
   variable) — reroute toutes les conversations simples vers Claude
   immédiatement, sans toucher au code.

Dans les deux cas : **zéro changement Flutter, zéro changement de règles
Firestore, zéro changement de Cloud Function financière.**

## 7. Variables d'environnement (résumé — voir `.env.example` pour le détail)

| Variable | Rôle | Défaut |
|---|---|---|
| `OPENAI_API_KEY` | Clé API OpenAI | absente = non configuré |
| `OPENAI_MODEL` | Modèle par défaut | `gpt-4o-mini` |
| `OPENAI_MAX_OUTPUT_TOKENS` | Plafond de sortie | `1024` |
| `OPENAI_TIMEOUT_MS` | Timeout réseau | `30000` |
| `AI_OPENAI_TOOL_CALLING_ENABLED` | Autorise OpenAI sur un tour à outils | `false` |
| `AI_DEFAULT_PROVIDER` / `AI_COMPLEX_PROVIDER` / `AI_IMAGE_PROVIDER` / `AI_TOOL_PROVIDER` | Routage par type de requête | `claude` |
| `AI_FALLBACK_PROVIDERS` / `AI_ALLOWED_PROVIDERS` | Listes CSV | voir `.env.example` |
| `AI_ENABLE_FALLBACK` / `AI_ENABLE_CACHE` / `AI_ENABLE_METRICS` | Interrupteurs | `false` / `true` / `true` |
| `AI_MODEL_PRICING` | Grille tarifaire JSON par modèle exact | absente = repli sur le tarif par provider |

## 8. Scénarios formellement interdits sur OpenAI aujourd'hui

- Tout tour comportant des outils (`tools.length > 0`) tant que
  `AI_OPENAI_TOOL_CALLING_ENABLED` n'est pas `true` **et** que
  `functions/azia/index.js` n'a pas été explicitement révisé (il force
  `claude` en dur indépendamment de ce flag).
- Toute action financière : wallet, paiement, remboursement, annulation,
  création de commande, confirmation `ai_pending_actions` — restent
  exclusivement sur Claude par construction (`AI_TOOL_PROVIDER=claude` par
  défaut + garde `tools_openai_disabled` + `forceProvider:'claude'` en dur).
- Rejeu automatique d'un outil après une panne fournisseur — jamais permis,
  quel que soit le fournisseur (voir Mission 7 / rapport final §8).

## 9. Rollback plan (zéro changement Flutter)

1. `functions/.env` : vider `OPENAI_API_KEY` et/ou remettre les 4 variables
   `AI_*_PROVIDER` à `claude` (ou les retirer).
2. Redéployer uniquement les Cloud Functions AZ IA concernées
   (`firebase deploy --only functions:azIaChat` par ex.) — aucune règle
   Firestore, aucun schéma de données, aucun écran Flutter n'est impliqué.
3. Optionnel, pour retirer le code lui-même sans risque : `OpenAIProvider.js`
   peut être remis à son état d'avant ce chantier (delegate vers
   `OpenAICompatibleProvider`) sans affecter `ClaudeProvider`/le reste — les
   deux classes sont indépendantes et jamais couplées.
