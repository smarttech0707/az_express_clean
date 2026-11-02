# Arbre isolé de préproduction — différences avec le code de production

Date : 2026-10-31. Arbre : `%TEMP%\az_isolated_reliability` (copie du dépôt à `7a76f18` + lot minimal de fiabilité). Il sert uniquement à déployer dans `az-express-preprod`. **Aucune de ces différences n'existe dans le dépôt de production.**

## Différences de code (fonctions)

| Fichier | Différence | Pourquoi | Effet sur les 4 fonctions déployées |
|---|---|---|---|
| `functions/preprodSecretsShim.js` (nouveau, isolé seulement) | `defineSecret(nom)` renvoie `{ name, value: () => process.env[nom] || '' }` | le CLI exige dans Secret Manager chaque paramètre secret déclaré (FEEXPAY_TOKEN, FEEXPAY_WEBHOOK_SECRET, ANTHROPIC_API_KEY, DELIVERY_PROOF_PEPPER, GEMINI_API_KEY), même pour des fonctions non déployées | aucun : aucune des 4 n'utilise de secret |
| `functions/index.js` ligne 7 | `require('firebase-functions/params')` → `require('./preprodSecretsShim')` | idem | aucun |
| `functions/index.js` fin de fichier | boucle qui supprime `__endpoint.secretEnvironmentVariables` de chaque export | sinon le CLI active Secret Manager dès qu'**une** des 122 fonctions du code lie un secret (`ensureAllRequiredAPIsEnabled` s'applique à tout le code, pas au filtre `--only`) | aucun : métadonnées de déploiement seulement |

Vérifié (manifeste généré localement, `firebase-functions` 7.3.2) : 122 endpoints avant et après ; paramètres secrets 5 → 0 ; endpoints avec secrets → 0 ; les 4 fonctions retenues ont une définition **strictement identique** (déclencheur, région, maxInstances, mémoire) ; aucun autre endpoint ne change hors secrets. Conséquence : les fonctions de paiement, d'IA et de preuves QR, **si elles étaient déployées depuis cet arbre**, n'auraient plus accès à leurs secrets — elles ne doivent pas l'être.

Aucune protection financière ou de sécurité n'a été retirée ; aucun fichier métier (`orderActions.js`, `driverAcceptance.js`, `dispatch.js`, `driverLifecycle.js`) n'est modifié par cette étape.

## Différence 2 — `syncDriverOrderLifecycle` : retry désactivé (décision du propriétaire, 2026-10-31)

| Fichier | Production / dépôt | Arbre isolé de préproduction |
|---|---|---|
| `functions/index.js` ligne 114 | `retry: true` | `retry: false` (+ commentaire) |

Pourquoi : avec `retry: true` le CLI exige `--force` (« failure policy ») car les exécutions en échec sont réessayées en boucle jusqu'à 7 jours et facturées. Décision : ne pas utiliser `--force` pour le premier déploiement.
Effet : si l'exécution échoue (erreur transitoire), elle n'est **pas** rejouée automatiquement ; la fonction n'est qu'une réparation (libère les offres résiduelles et le livreur), `deliverOrderCF` libère déjà le livreur lui-même. Le déclencheur (mise à jour de `orders/{orderId}`), la région (europe-west1), `maxInstances` (1) et le code du handler sont inchangés ; manifeste local : seul cet endpoint diffère du précédent, et seulement par `eventTrigger.retry`.
À tester avant le lancement commercial : le comportement avec `retry: true` (réessais, idempotence, coût).

## Différences de contenu par rapport au dépôt de travail
- `firestore.rules` : règles de production déployées + 4 champs serveur (`cancelRequestAfterPickup`, `disputeDecision`, `adminDeliveryConfirmation`, `deliveryClosedBy`) ; `orderActions.js`, `driverRelease.js`, `adminOrderDisputes.js` : lot de fiabilité (litiges, commission non tracée).
- `.firebaserc` : projet par défaut `az-express-preprod` (le dépôt a `az-express-b0469`).
- `functions/.env.az-express-preprod` (SMS coupés, `FEEXPAY_SHOP_ID=DISABLED`) ; pas de `functions/.env` de production.
- `fb-rules.json`, `fb-storage.json` : configurations d'émulateur locales (ports 8097/9197).
- `node_modules` : jonctions vers ceux du dépôt (racine et `functions/`).

## Résultats de tests (arbre isolé)
- `functions` : `npm test` — 1559 tests : 1511 réussis, 47 ignorés (tests sur émulateur), **1 échec connu** : `partnerQrCache.test.js` lit un `firebase.json` absent de `functions/` (échoue aussi sur le dépôt à HEAD tant que le chantier QR n'est pas intégré).
- `rules-tests` Firestore : 377 / 377. Storage : 120 / 120.
