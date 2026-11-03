# Plan — tarifs calculés côté serveur : Colis, Blanchisserie, Eau & Boissons

Analyse seule (aucun fichier de code modifié). Sources : `colis_page.dart`, `blanchisserie_page.dart`, `eau_boissons_page.dart`, `firestore.rules`, `functions/orderActions.js`, `deliveryQuote.js`, `tariffConfig.js`.

## 1. Inventaire technique

| | Colis | Blanchisserie | Eau & Boissons |
|---|---|---|---|
| Tarif actuel | Prix par type : standard 500, cadeau 700, document 300, gros colis 1000 ; fragile +200 | `pricePerKg` × kilos ; défaut 1000 FCFA/kg | Σ quantité × prix produit + frais de livraison 500 |
| Origine des prix | Constantes de l'écran (`_fallbackTypes`), surchargeables par `app_config/colis` | Constante 1000, surchargeable par `app_config/blanchisserie` | Catalogue de l'écran (`_fallbackProducts`), `app_config/eau_boissons` (produits, `deliveryFee`) |
| Paramètres | type, fragile | service, quantité (kg, entier ≥ 1) | produits et quantités (panier) |
| Frais supplémentaires | fragile +200 | aucun | livraison 500 (fixe) |
| Distance / zone | aucune (latitude = longitude = 0) | aucune | aucune |
| Paiements | cash, wallet | cash, wallet | cash, wallet |
| Montants dans `orders` | `budget` = prix, `shoppingBudget` = 0 | `budget` = prix, `shoppingBudget` = 0 | `budget` = livraison, `shoppingBudget` = articles |
| Écritures wallet | Transaction client : débit + `lastPaidOrderId` + création commande ; puis ligne `purchase` du journal ajoutée à part | idem | idem |
| Annulation | `cancelOrderCF` (Phase A) : remboursement `budget + shoppingBudget` si wallet payé, avant récupération | idem | idem |
| Livraison | `deliverOrderCF` crédite le livreur de `budget + shoppingBudget` si `isPaid`, commission prélevée à l'acceptation | idem | idem |
| Fonctions serveur existantes | `cancelOrderCF`, `deliverOrderCF`, `acceptOrder` ; **aucune** fonction de création ni de prix pour ces trois services | idem | idem |

**Constat important (lecture des règles).** `app_config/{id}` n'est lisible par un client que pour `blanchisserie` (`firestore.rules`, bloc `app_config`). Pour `colis` et `eau_boissons`, la lecture échoue silencieusement (`catch (_) {}`) : **les clients paient toujours les prix constants du code**, quoi que contienne `app_config` en production. Pour `blanchisserie`, le prix et la liste des services viennent bien de `app_config/blanchisserie` (modifiable par un administrateur). Je n'ai pas lu la production : les valeurs réelles de ces trois documents sont à vérifier (lecture seule autorisée par vous) avant de figer un catalogue officiel.

## 2. Risques constatés

**Manipulation des prix (élevé).** La règle de création de `orders` n'impose que `budget` entier ≥ 500 ; elle ne connaît ni le service, ni le barème. Un client direct à Firestore peut donc commander 50 kg de blanchisserie avec `budget` 500, ou un panier d'eau à 500 FCFA, et payer ce montant par wallet : `walletDebitMatchesPaidOrder` vérifie seulement que le débit égale `budget + shoppingBudget`, pas que ce total est le bon. Rien ne contrôle non plus `shoppingBudget` à la création (à confirmer par un test de règles). Le livreur est ensuite crédité du montant écrit par le client.

**Double débit (moyen).** Chaque appui génère un nouvel identifiant (`Uuid().v4()`). Si la transaction aboutit mais que la réponse est perdue (coupure réseau), le client revoit une erreur, retente, et crée une seconde commande avec un second débit. Il n'y a pas de clé d'idempotence. Le journal `purchase` est écrit après coup, hors transaction : une commande payée peut exister sans ligne de journal.

**Autres constats.** Anonyme : `isRealUser()` refuse la création (le `signInAnonymously` de l'écran est donc inutile, et l'écran échoue). Les collections `blanchisserie_orders` et `eau_boissons_orders` sont encore ouvertes en création aux clients mais ne sont plus utilisées par le code Flutter (hors constantes). Les quantités ne sont pas plafonnées. Question métier non tranchée par le code : le livreur est crédité de 100 % du montant (service de blanchisserie, articles d'eau) ; aucun partenaire n'est payé. Je n'y touche pas.

## 3. Architecture proposée : réutiliser le devis officiel

Principe : mêmes briques que `createOrderFromQuoteCF` (devis dans `tariff_quotes` écrit par Admin SDK, création unique en transaction), sans distance.

1. **Catalogue serveur** (`functions/catalogTariff.js`, pur, testable) : prix de référence recopiés des constantes actuelles (`tariffConfig.js` a déjà des entrées `colis`, `blanchisserie`, `eau_boissons` avec `review: true`), versionnés (`catalogVersion`). Pour la blanchisserie, lecture d'`app_config/blanchisserie` par le serveur (Admin SDK), validée (entier, bornes), avec repli sur la constante. Aucune valeur inventée : aucun prix n'est modifié.
2. **`quoteCatalogCF`** : entrée = service + paramètres (type et fragile / service et kilos / produits et quantités + mode de paiement). Sortie = détail `{budget, shoppingBudget, lignes}` pour l'affichage. Écrit un devis `tariff_quotes/{id}` lié au client, au service, au hash des paramètres, à la version du catalogue, avec expiration courte et usage unique.
3. **`createCatalogOrderFromQuoteCF`** : une transaction relit le devis (propriétaire, ouvert, non expiré, paramètres identiques), recalcule le prix, puis : wallet → débit + ligne de journal `order_<id>` (identifiant déterministe) ; dans tous les cas `tx.create` de la commande avec `budget`/`shoppingBudget`/`isPaid`/`type` posés par le serveur ; devis marqué utilisé. **Identifiant de commande dérivé de l'identifiant du devis** : un rejeu (coupure réseau, double appui) retrouve la même commande, sans second débit. Si le prix courant a augmenté depuis le devis : `PRICE_CHANGED`, rien n'est débité (comme aujourd'hui pour la livraison).
4. **Données conservées** : la commande garde exactement la forme actuelle (`type`, `colisType`, `quantity`, `items`, `budget`, `shoppingBudget`, `description`…) : acceptation, livraison, annulation, commission, notifications et écrans livreur restent inchangés.
5. **Flutter** : chaque écran appelle `quoteCatalogCF` à l'étape de confirmation, affiche le montant serveur, puis `createCatalogOrderFromQuoteCF` avec la clé du devis ; mêmes protections que E-Kbine (clé conservée après coupure, anti double appui, messages d'erreur). Les constantes de prix de l'écran servent seulement d'estimation avant le devis, puis disparaissent.
6. **Règles (dernière étape)** : après version minimale de l'application, interdire la création client des commandes `type in ['colis','blanchisserie','eau_boissons']` (règle ciblée, sans toucher aux autres types), puis fermer les deux collections `*_orders` inutilisées.
7. **Quota Cloud Run** : 2 fonctions à 0,5 CPU × 2 instances (+2) ; elles serviront ensuite à Boulangerie, Restaurant, Pharmacie, etc.

## 4. Découpage proposé
1. Catalogue serveur + `quoteCatalogCF` + tests unitaires (aucun écran touché).
2. `createCatalogOrderFromQuoteCF` + tests de concurrence sur émulateur (8 appels sur un même devis : un débit, une commande).
3. Écran Colis (le plus simple), tests Flutter avec appel remplaçable.
4. Blanchisserie, puis Eau & Boissons.
5. Règles ciblées et script de rapprochement (commandes déjà passées à un prix non officiel, lecture seule).
6. Déploiement : fonctions, puis application, puis règles.

## 5. Décisions requises avant de coder
1. Prix officiels : confirmer que les constantes actuelles du code font foi (c'est ce que paient réellement les clients pour Colis et Eau) et lecture seule autorisée de `app_config/{colis,blanchisserie,eau_boissons}` en production pour comparer.
2. Plafonds : kilos maximum par commande de blanchisserie, quantité maximale par produit et total du panier d'eau (aujourd'hui aucun plafond).
3. Colis : le prix reste-t-il fixe par type (comportement actuel, aucune distance), ou un barème par distance est-il voulu plus tard (nécessiterait des coordonnées, absentes aujourd'hui).
4. Blanchisserie : `pricePerKg` doit-il rester modifiable par l'administrateur (source = `app_config/blanchisserie`, lue côté serveur) ?
5. Question métier hors périmètre technique : rémunération du prestataire (laverie, fournisseur d'eau) puisque le livreur reçoit 100 % du montant.
