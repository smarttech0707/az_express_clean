# Scénario S1 — livraison fictive complète (préproduction) — PRÉPARATION

Date : 2026-10-31. Projet : `az-express-preprod` (306761725053). **Rien n'est créé ni écrit** : ce document et `test-env/scenarios/s1-seed.json` (données seules) décrivent ce qui le sera après autorisation.

## 1. Les 4 fonctions suffisent-elles ?

**Oui pour le parcours nominal, sans désactiver aucune protection** (vérifié par lecture du code et des règles) :

| Étape | Qui / quoi | Fonction ou règle utilisée |
|---|---|---|
| Création + paiement | le client, une seule transaction Firestore : débit du wallet **et** écriture de la commande (`isPaid: true`) | règles `orders` (`walletDebitMatchesPaidOrder`, budget ≥ 500) — aucune fonction |
| Recherche + proposition | le client appelle `dispatchOrderToDriver` | ✅ déployée |
| Acceptation | le livreur appelle `acceptOrderCF` (selfie obligatoire dans Storage) | ✅ déployée + bucket/règles Storage ✅ |
| (Récupération) | le livreur passe `accepted → picked_up` par écriture directe autorisée par les règles — **facultative** : `deliverOrderCF` accepte `accepted` ou `picked_up` | règles |
| Livraison + crédit | le livreur appelle `deliverOrderCF` | ✅ déployée |
| Libération du livreur | faite par `deliverOrderCF` lui-même ; `syncDriverOrderLifecycle` (déclencheur) en filet de sécurité | ✅ déployée |

Non nécessaires à S1 : `enforceOrderRateLimit`, `notify*` (push FCM seulement), `autoExpireOrders`, `payOrderFromWalletCF` (le paiement wallet est fait à la création), `checkClientPhone`/`logAuthEvent` (connexion par l'app). **Scénarios qui exigeront d'autres fonctions** : S2/S6/S10 (`autoExpireOrders`), S4/S5 (`cancelOrderCF`, `releaseOrderBeforePickupCF`), S8 (`notify*`), S12 (`adminOrderDisputeCF`, `adminConfirmDeliveryCF`, `createSubAdmin`), connexion avec l'APK (`checkClientPhone`, `logAuthEvent`).

## 2. Comptes et données (fictifs)

| Élément | Valeur |
|---|---|
| Client | `preprod-client-s1@example.invalid` — doc `clients/<uid>` : wallet **20 000** |
| Livreur | `preprod-driver-s1@example.invalid` — doc `livreurs/<uid>` : wallet **5 000**, en ligne, disponible, non suspendu, `currentCityId=abengourou`, GPS fictif `6.7285, -3.4955`, `updatedAt` = maintenant |
| Ville | `zones_livraison/abengourou-test` : centre `6.7273, -3.4961`, rayon 8 km, `coordinateSource: own` (sans elle le dispatch est refusé) |
| Commande | `budget 500`, `shoppingBudget 0`, `paymentMethod wallet`, `isPaid true`, point de collecte `6.7290, -3.4950`, destination `6.7310, -3.4925`, `pickupCityId abengourou`, `cityResolutionStatus resolved` |
| Selfie | JPEG synthétique < 100 Ko, `acceptance_selfies/<orderId>/<uidLivreur>.jpg` |
| Configuration | aucune : sans `config/commission` la commission vaut 100 (< 1000) ; sans `config/billing` la politique par défaut s'applique |

Mots de passe générés localement, jamais dans le dépôt. Identifiants `.invalid` : aucune adresse réelle. Aucune donnée personnelle, aucun numéro réel.
Contraintes de temps : le GPS du livreur est écarté s'il a plus de **3 minutes** (`STALE_MINUTES`) — écrire `updatedAt` juste avant le dispatch.

## 3. Déroulement et valeurs attendues

| # | Action (jeton de l'acteur) | Attendu |
|---|---|---|
| 0 | état initial | client 20 000, livreur 5 000, total **25 000**, AZ 0 |
| 1 | client : transaction débit + création | client **19 500** (`lastPaidOrderId` = commande), commande `pending` |
| 2 | client : `dispatchOrderToDriver` | `dispatched: true`, mode `assigned` (un seul livreur éligible) → `status assigned`, `driverId` posé |
| 3 | livreur : téléverse le selfie (règles Storage) | objet créé ; chemin imposé = son uid |
| 4 | livreur : `acceptOrderCF` (URL du selfie) | livreur **4 900**, `isOnDelivery true`, commande `accepted`, `commissionAmount 100`, `commissionStatus charged`, `commissionTxId commission_<commande>_<livreur>`, 1 `wallet_transactions` de type `commission` (100) |
| 5 | (facultatif) livreur : `picked_up` | statut `picked_up` |
| 6 | livreur : `deliverOrderCF` (+ GPS fictif) | commande `delivered`, livreur **5 400** (crédit 500, commission déjà prélevée), `isOnDelivery false`, `deliveries 1`, `wallet_transactions` : `commission 100` + `earning 500`, doc `commissions` (100, `traced`, gain livreur 400), `config/az_wallet` : `totalCommissions 100`, `totalDeliveries 1` |
| 7 | contrôle final | client 19 500 + livreur 5 400 + AZ 100 = **25 000** (conservation) |

Vérifier à chaque étape par lecture Admin (aucune écriture) : soldes, statut, `commission*`, `wallet_transactions`, `commissions`, `config/az_wallet`, `rate_limits`, journaux des 4 services.

## 4. Contrôles d'anti-doublon et de sécurité (sans désactiver aucune protection)

| Contrôle | Attendu |
|---|---|
| Étape 4 rejouée (même livreur, puis 5 appels simultanés) | une seule commission : `alreadyAccepted`, livreur reste 4 900, 1 seule `commission_…` |
| Acceptation sans selfie / URL d'un autre livreur | `SELFIE_REQUIRED`, aucun débit |
| Étape 6 rejouée après livraison | refus (`ne peut pas être marquée livrée`), aucun second crédit |
| Le client appelle `deliverOrderCF` | `permission-denied` (commande non assignée à lui) |
| Création avec un débit qui ne correspond pas | refusée par les règles |
| Livreur avec wallet < 100 | écarté du dispatch / `CREDIT_INSUFFISANT` |
| Deux livreurs (2ᵉ compte fictif, **autorisation séparée**) | un seul gagne ; l'autre `permission-denied`, solde intact |

## 5. Blocages et risques

1. **Authentication n'est pas initialisée** dans `az-express-preprod` (`CONFIGURATION_NOT_FOUND`) : impossible de créer les comptes tant que ce n'est pas fait. Option recommandée : console Firebase > Authentication > « Commencer » + activer **Email/Mot de passe** (gratuit ; ne pas passer à Identity Platform ni activer SMS). **Décision requise.**
2. Les appels se feront par script avec de vrais jetons d'identité (même chemin que l'app : règles et fonctions réellement appliquées) ; la clé Web API de préproduction est dans `google-services.json` (`C:\\az-test`). Aucune connexion par l'APK nécessaire pour S1.
3. Dispatch : GPS livreur périmé après 3 min ; ville sans `coordinateSource: own` ⇒ refus.
4. `syncDriverOrderLifecycle` est sans réessai (différence 2) : une erreur transitoire n'est pas rejouée ; ici sans effet car `deliverOrderCF` libère le livreur.
5. Écritures post-transaction non atomiques (compteurs, `commissions`, `az_wallet`) : un arrêt à cet instant laisse un journal incomplet, jamais un double crédit.
6. Les données restent dans le projet de test : nettoyage par suppression des documents fictifs ; le selfie disparaît seul après 30 jours (cycle de vie).
7. Coût attendu : quelques centièmes d'USD (quelques invocations, 1 objet).
