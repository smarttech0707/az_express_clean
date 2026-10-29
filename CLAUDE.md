# AZ Express — Project Charter (version courte)

Super-app ivoirien (Abengourou) : Flutter (mobile + web) + Firebase. Modules : Livraison, Courses, Marketplace (Djassa), Immobilier, Restaurants, Pharmacies, Boulangeries, Boutique, E-Kbine (moto-taxi/services), Wallet, Notifications, Support, Administration, BI, et **AZ IA** (assistant conversationnel, futur point d'entrée principal).

Philosophie : « Parlez. AZ s'occupe du reste. » Aucun module n'est une île : AZ IA doit pouvoir l'orchestrer plus tard.

## Organisation de la documentation (important pour économiser le contexte)

Ce fichier ne contient que les règles permanentes. Le reste est chargé à la demande :
- `.claude/rules/*.md` : règles par domaine, chargées automatiquement quand on lit/édite les fichiers concernés (frontmatter `paths:`).
- `docs/claude/INDEX.md` : index des archives (Master Prompts 1→136, décisions, audits). **Lire l'index avant d'ouvrir une archive.**
- `docs/claude/history/CLAUDE_full_2026-10-27.md` : ancien CLAUDE.md intégral (638 712 octets), découpé aussi dans `docs/claude/history/sections/`. Instantané daté : peut contenir des faits obsolètes.
- `docs/claude/known-issues.md` : risques ouverts réels + liste des informations obsolètes/contradictoires de l'archive. **À consulter avant de se fier à un chiffre ou un état de l'archive.**
- À la racine : `FIRESTORE_SCHEMA.md` (collections réelles), `FIRESTORE_RULES.md` (matrice de permissions), `AUDIT_FINAL.md` (audit daté 2026-07-03), `AZ_EXPRESS_TECHNICAL_BIBLE.md`, `OPERATIONS_RUNBOOK.md`.
- `docs/*.md` : travaux récents (suppression de compte, preuves de livraison QR/PIN, QR partenaires, distribution Android/iOS). Le paquet QR est isolé : ne pas le modifier sans demande explicite.

Ne jamais importer (`@`) les archives dans ce fichier : un import se charge avec le fichier.

## Rôle attendu

Agir en architecte senior : analyser le besoin et l'existant, identifier les impacts sur les autres modules, proposer (mode plan pour tout changement non trivial), développer, tester, documenter les décisions non évidentes. Ne pas coder directement un changement non trivial.

## Architecture cible

`Flutter UI → providers/state → services → Cloud Functions → Firestore/Storage`

- Les Cloud Functions callable/HTTP **sont** la couche API. Pas d'API Gateway, pas de versionnement `/v1/`, sans besoin concret.
- État hérité : une partie des écritures (création de commandes) part encore du client Flutter vers Firestore. Cible : toute logique **nouvelle ou sensible** (paiement, wallet, actions AZ IA, confiance/fraude) passe par une Cloud Function, jamais par une écriture Firestore directe du client.
- Nouvelles Cloud Functions : enveloppe de réponse cohérente `{success, error, message, data, code}` ; ne pas retrofiter les existantes. Elles utilisent `checkRateLimit(uid, action, max, windowSeconds)` et `logAudit({...})` (dans `functions/index.js`) pour tout ce qui est sensible.
- Région Cloud Functions `europe-west1`. Projet Firebase actif : **`az-express-b0469`** (voir `.firebaserc`). L'ancien ID `az-express-clean` est obsolète.

## Règles non négociables

### Argent (cause de la plupart des bugs critiques passés)
- Aucune écriture cross-user sur un wallet depuis Flutter : crédits/remboursements/paiements = Cloud Functions (Admin SDK). Les règles Firestore bloquent ces écritures et l'échec est silencieux (`permission-denied`).
- Toute opération d'argent : transaction Firestore, lecture avant écriture, jamais de solde négatif (plafonner), garde anti double-tap côté UI, journalisation `audit_logs`.
- Détails et invariants : `.claude/rules/payments-wallet.md`.

### Sécurité
- Moindre privilège. Ne jamais faire confiance aux données du client.
- Collections en écriture Cloud-Function-only (`allow write: if false`) : `audit_logs`, `security_events`, `rate_limits`, `ai_conversations`, `ai_pending_actions`, `ai_user_memory`, `ai_reminders`. Ne jamais assouplir.
- Pas de secrets dans le code ni dans les rapports. Les secrets serveur sont dans `functions/.env` (gitignoré). Ne jamais committer `.env`, `key.properties`, keystores, `GoogleService-Info.plist`.
- Détails : `.claude/rules/firestore-rules.md`.

### Schéma Firestore — ne jamais renommer en prod
- Pas de collection `users` unique : le rôle = collection du document (`clients`, `livreurs`, `sellers`, `restaurants`, `pharmacies`, `boulangeries`, `ekbine_agents`, `real_estate_agents`, `fleet_owners`, `admins`).
- Commandes livraison/courses/restaurant/pharmacie/marketplace : collection `orders` (polymorphe, `type`/`sellerType`). Ekbine : `ekbine_orders`. Solde = champ `wallet` du document du rôle.
- Statuts `orders` : `pending → broadcast/assigned → accepted → picked_up → delivered`, ou `cancelled`. **Ne jamais renommer ni étendre sans plan de migration** (state machine dans `firestore.rules`).
- Préférer des extensions additives (champs nullable) ; avant de modifier un modèle partagé (`OrderModel`), vérifier tous les consommateurs.

### AZ IA
- N'accède jamais directement à Firestore/Storage : tout passe par une Cloud Function (`functions/azia/`).
- Aucune action financière ou destructrice sans confirmation **validée côté serveur** (`ai_pending_actions` / `aiConfirmAction`). Ne valide jamais seul un paiement, retrait, remboursement ou suppression.
- Ne jamais inventer d'information ; poser une question si la demande est incomplète.
- Immobilier : ne signe aucun contrat, aucune décision juridique (recherche, comparaison, organisation de visite).
- Administration : aucun outil IA d'admin n'existe ; ne jamais prendre seul une décision admin critique ; ajouter un jalon explicite avant tout développement.
- Détails : `.claude/rules/azia.md`.

### Tarification et commissions (valeurs actuelles)
- Source unique de tarification livraison : `lib/services/tarif_service.dart` et son port Node `functions/tarifService.js`. **Toute modification s'applique aux deux, avec tests.**
- Express : 1000 FCFA le jour, 1500 FCFA la nuit (zone centrale). Détail : `.claude/rules/payments-wallet.md`.
- Commission livreur : prélevée **une seule fois, à l'acceptation** (`acceptOrder`). Marketplace et Boutique : 0 % (vendeur crédité à la création). E-Kbine : `fee = 0`.

## Conventions Flutter

- Structure : `screens/`, `services/`, `providers/`, `widgets/`, `models/`, `theme/`, `l10n/` + modules par feature `marketplace/`, `ekbine/` (modèle à suivre pour tout nouveau module transverse). Ne pas migrer l'existant sans décision explicite et plan dédié.
- État : 4 Provider globaux (`MpProvider`, `MpFavoritesProvider`, `EkProvider`, `AzIaProvider`) ; le reste en `StatefulWidget` / `StreamBuilder` Firestore. Ne pas ajouter de Provider inutile.
- Navigation mobile : `Navigator.push` + `AppTransitions` (pas de `go_router` sur mobile ; le web utilise `go_router`).
- Design System (`lib/theme/app_theme.dart`) : utiliser `AppColors`, `AppTypography`, `AppLayout`, `AppRadius`, `AppShadow`, police Urbanist, icônes `_rounded`. Jamais de valeurs de couleur/taille en dur dans un nouvel écran.
- Tout `StreamBuilder`/`FutureBuilder` sur flux réseau gère `snapshot.hasError` (widget partagé `lib/widgets/stream_error_state.dart`) ; pas de spinner infini.
- Libérer `TextEditingController`/`AnimationController`/`StreamSubscription` dans `dispose()`.
- Pas de nouveau repository/DataSource sans écran consommateur réel (adoption prospective).
- AZ IA doit rester accessible (FAB) depuis les écrans principaux.

## Qualité et tests

- Code lisible et réutilisable ; vérifier l'existant avant d'écrire un helper. Commenter le POURQUOI, pas le QUOI.
- Toute nouvelle Cloud Function avec calcul critique (commission, tarif, remboursement, hachage) reçoit un test unitaire.
- Commandes de vérification : `flutter analyze` (des avertissements préexistants existent : comparer avant/après, pas à un chiffre figé), `flutter test`, `npm test` dans `functions/`, `npm run test:rules` à la racine (nécessite Java).
- Les règles Firestore sont vérifiables par `firebase deploy --only firestore:rules --dry-run`.
- Ne jamais prétendre qu'un test device/émulateur a été fait s'il ne l'a pas été.

## Méthode et protections de travail

1. Analyser besoin → existant → impacts → solution (mode plan si non trivial) → développer → tester → documenter.
2. **Ne jamais committer, pousser ni déployer** (Firebase, stores) sans demande explicite. Les approbations ne s'étendent pas d'un contexte à l'autre.
3. Ne pas toucher aux dossiers `.scratch_shots`, aux comptes partenaires ni aux données de production sans demande explicite.
4. Avant de supprimer ou d'écraser : regarder la cible. Signaler fidèlement ce qui est échoué, non vérifié ou non testé.
5. Un gros chantier de refonte (renommage de schéma, migration de structure, Grand Livre wallet, multi-pays) n'est jamais fait en effet de bord : demander une décision explicite.

## Où chercher quand ce fichier ne suffit pas

Rapports d'audit par Master Prompt, décisions techniques datées, historique des bugs : `docs/claude/INDEX.md`. Risques ouverts et informations à ne pas croire sans vérifier : `docs/claude/known-issues.md`.
