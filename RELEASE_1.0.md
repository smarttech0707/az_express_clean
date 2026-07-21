# AZ Express — Release 1.0

## Version

**1.0.0** (Release Candidate 1.0 — gel de version)

## Date

2026-07-21

---

## Fonctionnalités incluses

- **Livraison** — création de commande, dispatch serveur, suivi temps réel, preuve de livraison (photo + GPS), annulation, expiration automatique (10 min sans livreur).
- **Wallet** — solde, recharge (FeexPay : Orange Money, MTN MoMo, Moov Money, Wave), retrait, historique de transactions, conciliation hebdomadaire automatique.
- **Paiements** — cash à la livraison et wallet sur tous les modules marchands (Livraison, Courses, Marketplace, Boutique, Restaurant, Pharmacie, Boulangerie, E-Kbine).
- **Marketplace (Djassa)** — recherche/filtre produits, favoris, chat acheteur↔vendeur, signalement d'abus.
- **Boutique AZ** — catalogue produit géré par l'admin, achat cash et wallet, historique de commandes, remboursement automatique si non livré sous 48h.
- **Restaurants** — dashboard propriétaire (gestion de menu réelle), recherche/commande côté client, workflow complet menu→commande→livraison.
- **Pharmacie** — pharmacies de garde, commande de livraison, statut ouvert/fermé.
- **Boulangerie** — inscription, dashboard, commande.
- **Immobilier** — recherche de biens (agents vérifiés), demande de visite, workflow d'approbation agent.
- **Artisan / Services locaux** — annuaire de prestataires, gestion de photos de réalisations.
- **E-Kbine** — services instantanés (crédit, internet, mobile money), agents dédiés, suivi de commande.
- **Chat** — client↔livreur (livraison active), acheteur↔vendeur (Marketplace).
- **Notifications** — push FCM sur les événements de commande, wallet, E-Kbine, Immobilier ; centre de notifications in-app.
- **AZ IA** — assistant conversationnel (texte + vocal), mémoire utilisateur (M8 scopé), contexte automatique (profil, position), vision native (photos), confirmation serveur obligatoire pour toute action financière, réponses structurées par module.
- **Sécurité** — RBAC par collection, App Check (SDK activé, enforcement Cloud Functions non activé — voir Bugs connus), règles Firestore/Storage à moindre privilège, audit log sur toute action sensible.
- **Administration** — back-office mobile complet (commandes, wallet, zones, dispatch, sous-admins, sécurité) + back-office web (leads, SOS).

## Fonctionnalités volontairement absentes

Décisions de périmètre déjà actées, pas des oublis :

- **Multi-devises / multi-pays** — application codée pour la Côte d'Ivoire (FCFA), Abengourou spécifiquement pour les calculs de zone. Vision à 10 ans documentée, aucun chantier engagé.
- **Cartes bancaires** — seul le Mobile Money (via FeexPay) est supporté, cohérent avec le marché cible.
- **Transferts wallet-à-wallet entre utilisateurs** — jamais construits, risque de fraude/anti-blanchiment non conçu.
- **Prévision/BI prédictive pour AZ IA** — refusé explicitement (volume de données insuffisant pour des statistiques fiables, décisions stratégiques hors du périmètre d'un assistant IA).
- **Suspension de compte client** — existe pour les partenaires (vendeurs, agents E-Kbine), pas pour les clients.
- **Application des permissions granulaires par section pour les sous-admins au niveau des règles Firestore** — le filtrage existe côté UI uniquement ; un sous-admin actif a un accès Firestore complet, pas restreint par son tableau `permissions`.
- **Écran de gestion dédié pour la mémoire utilisateur AZ IA (M8)** — contrôle existant limité à l'effacement complet de l'historique de conversation, pas d'édition fine des préférences mémorisées.
- **Panier / checkout multi-vendeurs Marketplace** — parcours actuel : contact direct vendeur, pas de panier ni de paiement en ligne intégré au Marketplace lui-même.
- **Avis et notations produits/vendeurs** — le mécanisme de signalement d'abus existe, pas de notation.

## Bugs connus restants

- **App Check** : SDK client activé (Play Integrity/DeviceCheck), mais l'enforcement n'est activé sur aucune Cloud Function `onCall` — décision délibérée en attendant une période d'observation post-déploiement, pas un oubli.
- **iOS** : `PRODUCT_BUNDLE_IDENTIFIER` reste `com.example.azExpressClean` (jamais corrigé vers l'identifiant réel) ; aucun `Podfile` n'a jamais été généré ; le build iOS n'a jamais pu être testé dans l'environnement de développement utilisé pour cette release (nécessite une machine macOS). L'app n'est donc pas prête pour une soumission App Store en l'état.
- **Dépendances npm (Cloud Functions)** : `npm audit` a révélé 15 vulnérabilités transitives dans la chaîne `firebase-admin` (1 critique, 4 hautes), la plupart corrigibles sans changement cassant (`npm audit fix`), certaines nécessitant une montée de version majeure de `firebase-admin`. Non corrigées à ce jour — action recommandée avant un lancement à grande échelle.
- **Profil livreur (chargement)** — le correctif empêchant l'affichage de « 0 FCFA »/« 0 livraisons » avant le premier chargement réel n'a été vérifié que par lecture de code, faute de compte livreur approuvé disponible pour un test réel sur appareil au moment de la correction.
- **Firestore — 1 index en production absent du fichier local** (`firestore.indexes.json` : 41 index définis localement, 42 actifs en production) — un index existant côté serveur n'a jamais été rapatrié dans le fichier de définition ; sans risque fonctionnel connu, à nettoyer ou documenter lors d'une prochaine revue technique.
- **Versionnement** — `pubspec.yaml` (`1.0.0+1`) et les tags git (`v0.2-rc2`, `v0.3-rc3`, et désormais ce gel `v1.0-rc1`) suivent deux numérotations non synchronisées historiquement ; ce gel de version marque le point de départ d'un alignement à partir de maintenant.

## Règles métier importantes

### Livraison — Tarification

**Standard** : selon la grille officielle (zone centrale ≤8 km d'Abengourou : 500 FCFA jour / 1000 FCFA nuit ; hors zone : tarif kilométrique, refus des commandes de plus de 10 km après 21h00).

**Express** (zone centrale ≤8 km) :
- **Jour : 1000 FCFA**
- **Nuit : 1500 FCFA**

> Ces tarifs Express constituent une **règle métier officielle**, verrouillée dans le code (`lib/services/tarif_service.dart` et `functions/tarifService.js`, source unique de vérité partagée par tous les écrans et par AZ IA) et couverte par 14 tests automatiques (6 Dart + 8 Node) qui échoueraient immédiatement en cas de modification non désirée. **Ne jamais les modifier sans décision métier explicite.**

### AZ IA — règles non négociables

- Jamais d'accès direct à Firestore/Storage — toute action passe par une Cloud Function.
- Aucune action financière ou destructrice sans confirmation explicite de l'utilisateur, validée côté serveur (`ai_pending_actions`/`aiConfirmAction`).
- Jamais d'invention d'information — question de clarification si une donnée manque.
- Immobilier : recherche et organisation de visite uniquement, aucune signature de contrat ni décision juridique.
- Administration : aucune décision administrative critique prise seule par AZ IA.

### Wallet

- Transactions append-only pour les utilisateurs normaux (aucune modification/suppression possible après écriture).
- Remboursement toujours en crédit wallet interne, jamais un remboursement vers l'opérateur Mobile Money d'origine.
- Marketplace et E-Kbine : 0 % de commission (le vendeur/agent reçoit le montant intégral) — décision produit, pas un bug.

### Statuts de commande (state machine)

`pending → broadcast/assigned → accepted → picked_up → delivered`, ou `cancelled` — validée par une state machine explicite côté règles Firestore. Ne jamais renommer ni étendre ces statuts sans plan de migration dédié.

---

## Modules validés

✓ Livraison
✓ Wallet
✓ Paiements
✓ Marketplace
✓ Boutique
✓ Restaurants
✓ Pharmacie
✓ Firebase Storage
✓ Firestore
✓ Cloud Functions
✓ Notifications
✓ AZ IA
✓ Chat
✓ Immobilier
✓ Artisan
✓ Boulangerie
✓ E-Kbine
✓ Sécurité
✓ Administration

---

## Gel de version

À partir de ce document, **toute modification du projet doit être considérée comme une version 1.0.1, 1.1 ou 2.0** — plus jamais comme la version 1.0 elle-même. Seuls les bugs critiques découverts pendant la bêta peuvent être corrigés sans changer cette classification ; toute nouvelle fonctionnalité, tout refactoring ou tout changement de design constitue de facto une version suivante.

Voir `CHANGELOG.md` pour le détail chiffré de cette version, et `AUDIT_FINAL.md`/`CLAUDE.md` pour l'historique complet des audits ayant mené à ce gel.
