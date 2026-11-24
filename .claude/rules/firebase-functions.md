---
paths:
  - functions/**
  - firebase.json
  - .firebaserc
  - .github/workflows/**
---

# Cloud Functions et déploiement — invariants

Références : `docs/claude/INDEX.md` (prompts 23, 25, 37, 58, 61, 65-67, 83, 122), `OPERATIONS_RUNBOOK.md`.

- Projet actif `az-express-b0469`, région `europe-west1`, runtime `nodejs22` (voir `firebase.json` ; l'archive parle de Node 20, obsolète). `firebase-functions` 7.x (voir `functions/package.json`) : pas de montée majeure sans décision.
- ~58 fonctions (callable, triggers `notify*`, schedulers). Comparer `functions/index.js` à `firebase functions:list` avant d'affirmer un nombre.
- Quota Cloud Run CPU régional serré : ne pas augmenter `cpu` / `maxInstances` sans nécessité. Classement de criticité : A critique (AZ IA, paiements, wallet, dispatch) inchangé ; B/C réduits à `maxInstances:2` ; D (cron) `maxInstances:1`, `cpu:0.5`. Calcul : `Σ(cpu × maxInstances)`.
- Déployer par lots ciblés (`--only functions:a,functions:b`), jamais sans demande explicite. Une erreur « total allowable CPU per project per region » signifie qu'il faut réduire la charge, pas insister.
- Logique pure testable → module séparé (`passwordHash.js`, `dispatch.js`, `orderActions.js`, `realestate.js`, `tarifService.js`, `azia/*`). Les callables se testent via `.run(request)` sans émulateur.
- `withObservability` (`functions/observability.js`) existe mais n'est branché nulle part (sauf logique propre d'AZ IA) : décision à prendre avant de l'appliquer à du code financier.
- Secrets : `functions/.env` seulement (FeexPay, Anthropic). Jamais côté client, jamais affichés.
- App Check : SDK actif côté client, **`enforceAppCheck` non activé** côté fonctions. Ne l'activer qu'après rollout et période d'observation.
- Tests : `npm test` dans `functions/` (nombre variable : comparer avant/après). `node -c` + `require('./index.js')` pour vérifier le chargement.
- CI : `.github/workflows/ci.yml` (jobs flutter, functions, firestore-rules). Pas de job de déploiement.
