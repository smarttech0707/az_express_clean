# Devis catalogue serveur — Colis, Blanchisserie, Eau & Boissons (local, NON déployé, NON commité)

Branche `finalisation/az-express`. Suite du plan `PLAN_TARIFS_SERVEUR_COLIS_BLANCHISSERIE_EAU_2026-11-03.md`. Aucun écran Flutter modifié, aucune règle modifiée, aucun tarif modifié.

## Configuration de production (lecture seule, 2026-11-03)
`app_config/colis`, `app_config/blanchisserie`, `app_config/eau_boissons` : **les trois documents n'existent pas** (projet `az-express-b0469`, GET uniquement). Aucune différence à arbitrer : les clients paient exactement les constantes des écrans.

## Tarifs officiels (= tarifs actuellement appliqués)
| Service | Tarif |
|---|---|
| Colis | Standard 500 · Cadeau emballé 700 · Document / Enveloppe 300 · Gros colis 1000 · fragile +200 (prix fixe par type, sans distance) |
| Blanchisserie | 1000 FCFA/kg × kilos (4 services au même prix : Lavage + Repassage, Lavage uniquement, Repassage uniquement, Pressing) |
| Eau & Boissons | Eau 500ml 200 · Eau 1.5L 400 · Casier 3500 · Coca/Fanta/Sprite 500 · Jus 600 · Lait 700 · Énergisante 800 ; livraison 500 |

**« Document / Enveloppe » (300 FCFA) — décision du propriétaire : conservé et commandable (exception unique).** `minBudgetFor` (`catalogTariff.js`) fixe le minimum à 300 FCFA pour ce seul type ; tous les autres services/types gardent 500 FCFA (`BELOW_MINIMUM_ORDER`). Chaîne vérifiée : devis 300 → commande créée par l'Admin SDK (la règle client `budget >= 500` n'est pas traversée) → débit wallet 300 + journal `order_<id>` → annulation `cancelOrderCF` : remboursement exact 300 (testé) → acceptation : commission 100 FCFA (palier < 1000), le livreur garde 200 → livraison : crédit du budget 300. Aucun seuil dans acceptation/livraison/annulation. Fragile : 500.
**Dépendance de déploiement (NON incluse dans ce commit)** : la règle Firestore de création directe par le client (`budget >= 500`) reste inchangée ; l'ancien écran continue donc de refuser le Document tant que l'application n'utilise pas les fonctions. Aucune modification de règles n'est nécessaire pour ce tarif.

## Plafonds (provisoires validés — constantes `LIMITS` de `catalogTariff.js`, vérifiés côté serveur)
| Plafond | Valeur |
|---|---|
| Blanchisserie | 30 kg ; prix 1000 FCFA/kg ; bornes administrateur 100–10 000 FCFA/kg |
| Eau : unités par produit | 20 |
| Eau : casiers | 5 maximum |
| Eau : panier (articles) | 50 000 FCFA |
| Eau : poids estimé du panier | 50 kg (garde supplémentaire, provisoire, À CONFIRMER) |
**Compatibilité moto.** Un casier (12 × 1,5 L) pèse ≈ 19 kg estimés : 5 casiers ≈ 95 kg ne sont PAS transportables en un trajet. Le plafond de 5 casiers est donc conservé comme plafond par produit, mais une garde de poids estimé (`BASKET_TOO_HEAVY`, 50 kg) refuse en pratique plus de 2 casiers par commande. Les poids sont des estimations déduites des désignations ; la valeur 50 kg est à confirmer par l'équipe d'Abengourou. 30 kg de linge restent à la limite du volume d'une moto.
Aucune donnée client n'a été lue : les commandes historiques ne sont pas affectées (plafonds appliqués seulement aux nouveaux devis). Le montant maximal d'un panier reste très inférieur aux plafonds techniques existants (journal wallet 1 000 000).

## Prix au kilo modifiable par l'administration
Source : `app_config/blanchisserie` (champs `pricePerKg`, `services`), écriture déjà réservée au super-administrateur par les règles. Le serveur relit le document à CHAQUE devis et à CHAQUE commande ; valeur valide = entier de 100 à 10 000 (bornes provisoires) ; sinon valeur ignorée et prix par défaut 1000 (anomalie signalée dans le code). Si le prix change entre le devis et la commande : hausse → `PRICE_CHANGED` sans débit ; baisse → le client paie le moindre. Aucun écran d'administration n'écrit ce document aujourd'hui : prochaine étape proposée = fonction d'administration avec journal d'audit. `app_config/colis` et `app_config/eau_boissons` sont volontairement ignorés (non lisibles par les clients : leurs prix n'ont jamais pu varier).

## Répartition financière actuelle (inchangée)
| | Colis | Blanchisserie | Eau & Boissons |
|---|---|---|---|
| Prix du service / produits | `budget` = prix du type | `budget` = kilos × prix | `shoppingBudget` = articles |
| Frais de livraison | inclus dans le prix du type | inclus dans le prix au kilo | `budget` = 500 |
| Crédité au livreur (wallet payé) | `budget` | `budget` | `budget + shoppingBudget` |
| Commission AZ | 100 FCFA (budget < 1000) ou 200 | 100 ou 200 selon `budget` | 100 (budget 500) |
| Dû à un partenaire | aucun | **aucun** | **aucun** |
- **Le livreur achète-t-il les produits ?** Eau & Boissons suit le modèle « Courses » : le budget d'achat est affiché au livreur (« Courses : N FCFA »), aucune commande n'a de `sellerId`, donc aucun fournisseur n'est payé par AZ. Le livreur est censé avancer l'achat, puis reçoit `budget + shoppingBudget` à la livraison (wallet) ou garde le cash.
- **Blanchisserie** : aucun prestataire n'est modélisé ; le livreur est crédité de 100 % du prix. Si une laverie partenaire doit être payée, l'application ne le fait pas aujourd'hui.
- **Commission** : calculée sur `budget` seul, par paliers (100/200) : un lavage de 30 kg (30 000 FCFA) rapporte 200 FCFA à AZ ; la commission ne suit pas le prix.
- **Risques constatés (sans modification)** : (1) aucune preuve d'achat n'est exigée pour rembourser `shoppingBudget` au livreur (litiges possibles, cf. `adminOrderDisputes`) ; (2) un partenaire de blanchisserie/eau éventuel n'est pas rémunéré ; (3) commission fixe non proportionnelle ; (4) le crédit livreur mélange gain et avance remboursée (déjà noté dans `driver_rides_logic.dart`).

## Fonctions développées (`functions/catalogTariff.js`, `functions/catalogQuote.js`, exports dans `index.js`)
- **`quoteCatalogCF`** (0,5 CPU × 2) : authentifié (non anonyme), client actif, limitation de débit 30/min ; calcule le prix côté serveur, écrit `tariff_quotes/{id}` (`kind: 'catalog'`, client, service, paramètres canoniques, montants, version du catalogue, expiration 10 min, usage unique). Aucun montant du client n'est lu.
- **`createCatalogOrderFromQuoteCF`** (0,5 CPU × 2) : une transaction relit le devis (propriétaire, type catalogue, ouvert, non expiré), exige que la commande corresponde EXACTEMENT aux choix devisés, recalcule le prix courant, vérifie le compte (suppression en cours), débite le wallet (jamais de solde négatif, journal `order_<id>`), `tx.create` de la commande dans la forme de l'écran actuel (+ `tariffQuoteId`, `quotedAmount`, `catalogVersion`, `source`), marque le devis utilisé. Rejeu du même devis = même commande, aucun second débit. Espèces : aucun mouvement de wallet. Mobile money : refusé.
- Commandes créées compatibles avec `cancelOrderCF` (testé sur l'émulateur : remboursement exact `budget + shoppingBudget`, une seule fois, refus après récupération), acceptation, livraison et commission (champs inchangés).
- Non appelées par l'application actuelle : aucun parcours existant modifié.

## Tests
`functions/test/catalogQuote.test.js` (25, faux Firestore) et `functions/test/catalogConcurrency.emulator.test.js` (6, émulateur) : prix normal, prix et quantités manipulés, devis expiré, double commande, double débit, solde insuffisant/négatif, annulation et remboursement, concurrence (8 appels sur un devis : un seul débit ; 6 devis pour un solde : jamais négatif), droits d'accès, commandes historiques. Données fictives uniquement.
Note de concurrence : sous très forte contention, l'émulateur peut abandonner une transaction (erreur technique sans effet) ; le client rejoue et retrouve la même commande (testé).

## Avant tout déploiement
1. Confirmer la garde de poids (50 kg) ; décider du prestataire éventuel (blanchisserie/eau).
2. Écrans Flutter (étape suivante, non commencée) : devis à la confirmation, clé conservée après coupure réseau.
3. Ordre : fonctions → application → règles (fermeture ciblée de la création directe de `type in ['colis','blanchisserie','eau_boissons']`). Quota Cloud Run : +2.
