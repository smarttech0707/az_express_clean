# Fiabilité des commandes : corrections C1 / I1 / I2 et plans C2 / I3

État du 2026-10-30. **Tout est local et non déployé** (aucun commit, aucune règle, aucune fonction). Tests : `npm test` dans `functions/` = 1500 tests, 1466 réussis, 0 échec, 34 ignorés.

## 1. Causes exactes

| Id | Cause | Preuve |
|---|---|---|
| C1 | `refundAmounts()` (`functions/orderRefunds.js`), utilisée par `expireOrderTx` et `rateLimitCancelTx`, rendait `budget` (ou `totalAmount`) sans `shoppingBudget`. Le client wallet est pourtant débité de `budget + shoppingBudget` (règle `walletDebitMatchesPaidOrder`) ; `cancelOrderTx` le rendait correctement. | Calcul exécuté avant correction : `{budget:500, shoppingBudget:3000}` → 500 au lieu de 3500. 8 tests échouent si on retire la correction. |
| I1 | `cancelOrderTx` n'interdisait que `delivered`/`cancelled`. `cancelOrderCF` et l'outil AZ IA `cancel_order` acceptaient `picked_up` : remboursement intégral du budget et de la commission du livreur pour une commande ordinaire. L'interface ne propose l'annulation qu'en `pending`, mais le serveur est l'autorité. | Lecture de code + tests. 8 tests échouent si on retire la garde. |
| I2 | Le dispatch n'était lancé que par le client (`createOrder`, timers 30 s / 60 s de l'écran de suivi). Application fermée, réseau coupé ou aucun livreur au premier essai : plus aucune tentative. Même constat pour une commande remise en file par un livreur (refus / libération) si le nouvel essai échoue. | Lecture de code (`firestore_service.dart`, `customer_tracking_screen.dart`, `dispatch.js`, `driverDecline.js`, `driverRelease.js`). |

## 2. Corrections

**C1** (`functions/orderRefunds.js`) : `total = (budget ou totalAmount) + shoppingBudget` ; `sellerShare` ne contient jamais le `shoppingBudget` (le vendeur ne l'a pas reçu). Un `shoppingBudget` négatif ou non numérique est ignoré. Les conditions de remboursement sont inchangées : seulement `paymentMethod === 'wallet' && isPaid === true`, donc cash, pharmacie wallet non payée et course boutique ne sont jamais remboursés (rien n'a été débité). Idempotence : le statut est relu dans la transaction.

**I1** (`functions/orderActions.js`) :
- `cancelOrderTx` refuse un colis récupéré (`status === 'picked_up'` ou `pickedUpAt`) sauf `adminDecision` (fournie uniquement par `adminBilling`). La garde est dans la transaction.
- `cancelOrderCF` répond `failed-precondition` (message clair) et enregistre une demande `cancelRequestAfterPickup {status:'pending_admin_review', requestedBy, requestedAtMs}` sur la commande, une seule fois, sans rien rembourser.
- L'outil AZ IA `cancel_order` refuse à la proposition et à la confirmation.
- Annulations avant récupération et clôtures administratives (`closeStuckDelivery`, `resolveFeeHold`) : inchangées.

**I2** (`functions/dispatchRetry.js`, appelé par `autoExpireOrders`) :
- Comparaison : un trigger `onCreate` doublerait l'appel du client pour toutes les commandes, n'aiderait pas sans livreur en ligne, et ajouterait une fonction (quota Cloud Run CPU déjà serré). Un scheduler dédié ajouterait aussi une fonction. Choix retenu : une passe dans le scheduler existant (une fois par minute), après l'expiration (`try { expire } finally { retry }`) : zéro fonction ajoutée, une requête bornée à 50 commandes par minute, coût nul pour une commande normale.
- Seules les commandes `pending` sans livreur et en file depuis ≥ 30 s sont reprises. Essais à 30 s (2 km), 90 s (5 km), 150 s, 300 s, 480 s (30 km). Maximum 5 essais, intervalle minimal 45 s, arrêt à 9 min (l'expiration prend le relais).
- Un bail transactionnel (`order_dispatch_retries/{orderId}`, écrit par le serveur seul, jamais sur `orders` donc aucun trigger de commande) est pris avant chaque essai. La commande est relue `pending` dans cette transaction, et `dispatchOrder` la revérifie encore dans la sienne.
- Une remise en file (`requeuedAt`) repart de zéro et transmet `excludedDriverIds`. Une erreur de données (`DispatchError`) arrête la reprise pour cette commande.
- Aucun wallet touché : la commission reste prélevée une seule fois, à l'acceptation. Filtres GPS, distance, top 5, premier livreur qui accepte : inchangés (`dispatch.js` non modifié).

## 3. Fichiers modifiés

`functions/orderRefunds.js`, `functions/orderActions.js`, `functions/azia/tools/delivery.js`, `functions/index.js` (import + `autoExpireOrders`), nouveau `functions/dispatchRetry.js`.
Tests : nouveaux `test/orderReliability.test.js` (23) et `test/dispatchRetry.test.js` (15) ; adaptés `billingPickupPolicy`, `financialConservation`, `orderActions`, `stockReturn` (les tests qui faisaient annuler le client après récupération passent par la clôture administrative ou vérifient le refus).
Aucun fichier Dart modifié, aucune règle Firestore modifiée.

## 4. Risques financiers restants

- **Commande ordinaire récupérée puis litigieuse** : le client n'est plus remboursé seul, mais `adminBilling.closeStuckDelivery` ne traite que Marketplace/Boutique. Pour une livraison ordinaire il n'existe pas encore de décision administrative outillée (la demande est tracée, la résolution est manuelle). Décision à prendre (voir §7).
- **C2 (prix non contrôlé côté serveur)** : toujours ouvert, voir §5.
- **Commande `broadcast` jamais acceptée** : `dispatchOrder` ne reprend que `pending` ; elle reste diffusée aux mêmes 5 livreurs jusqu'à l'expiration à 10 min, puis est remboursée (C1 corrigé). Pas de perte d'argent, mais pas d'élargissement du rayon. Amélioration possible plus tard.
- **I3** : commandes `accepted`/`picked_up` sans suite, voir §6.
- Les tests de concurrence modélisent la sérialisation des transactions Firestore sur un faux : ce ne sont pas des tests sur émulateur. Un test d'émulateur existant (`marketplaceBoutiqueBilling.emulator.test.js`, expirations simultanées) n'a pas été relancé (Java/émulateur non démarré pour cette passe).
- Aucun test sur appareil ni sur Firebase de production des corrections.

## 5. Audit historique (lecture seule, 2026-10-30)

Script en lecture seule (aucune écriture) sur `az-express-b0469`, collection `orders` : **13 commandes au total** ; 6 expirées automatiquement (`no_driver_found`), 0 par limite de débit ; **0 commande wallet payée parmi les expirées** ; **0 cas C1** (aucun montant à rembourser rétroactivement) ; **0 annulation client après récupération** (I1). Aucun remboursement rétroactif n'est donc nécessaire ni effectué.

## 6. Plan C2 : contrôle serveur des tarifs (rien d'activé)

1. **Phase 0, observation sans blocage.** Dans `dispatchOrderToDriver` (déjà appelé pour chaque commande, qui relit la commande), calculer `functions/tarifService.js` avec la position de livraison et l'heure de création, et journaliser un événement `tariff_deviation` (id de commande, budget reçu, prix standard/express attendus, écart, distance à vol d'oiseau, distance annoncée si connue) sans rien modifier ni refuser. Pas de nouvelle collection de lecture publique : journal serveur.
2. **Règle de comparaison prudente.** La distance routière est toujours ≥ la distance à vol d'oiseau : le serveur calcule avec le vol d'oiseau (borne basse) et ne signale qu'un budget **inférieur** au plus petit prix attendu (standard) pour cette borne. Un budget supérieur ou égal n'est jamais un écart (route plus longue, express). Les cas à examiner séparément : course à cheval sur 20 h / 21 h (comparer l'heure de création et l'heure du dispatch), zone hors centre (> 8 km), courses libres et Courses (achats) dont `budget` n'est que la livraison, Marketplace/Boutique (montants explicites, `amountsVersion`), AZ IA (prix déjà calculé côté serveur).
3. **Critères de passage.** Au moins 14 jours et un volume significatif ; 0 faux positif sur des commandes légitimes ; liste des écarts examinée à la main. Seulement alors, proposer un mode `enforce` (refus du dispatch + annulation avec remboursement via le code unique `cancelOrderTx`) ; décision à valider par vous. Tarifs et commissions non modifiés. Toute évolution de `tarifService.js` s'applique aux deux ports (Dart et Node) avec tests.
4. Contrôle d'intégrité complémentaire, indépendant des tarifs : la règle `walletDebitMatchesPaidOrder` lie déjà le débit au budget écrit ; un budget trop bas coûte donc au client, pas à AZ, mais prive livreur et commission.

## 7. Plan I3 : commandes bloquées après acceptation (rien d'activé)

1. **Détection (lecture seule, sans effet financier).** Scheduler d'alerte (fréquence 5 à 10 min, à inscrire dans le groupe D du quota CPU, ou passe ajoutée à un scheduler existant) : commandes `accepted` sans changement depuis > 30 min, `picked_up` depuis > 90 min, sans position livreur récente. Écrit une alerte `security_events`/notification pour les administrateurs ayant la permission `commandes`. Ne modifie jamais la commande.
2. **Avant récupération (`accepted`).** Une réattribution assistée est déjà possible : le livreur peut se libérer (`releaseOrderBeforePickupCF`, commission rendue, remise en file, donc reprise par I2). Pour un livreur injoignable : action administrative explicite (super-admin, justification obligatoire, journal d'audit) qui exécute la même libération. Jamais automatique.
3. **Après récupération (`picked_up`).** Aucune réattribution automatique, aucun remboursement automatique. Intervention administrative : contact livreur/client, puis décision tracée. L'outil existe pour Marketplace/Boutique (`closeStuckDelivery`, `resolveFeeHold`). Pour une livraison ordinaire il manque une décision outillée : à ajouter après votre accord, en exigeant une décision explicite (rembourser le client, payer le livreur, ou conserver) plutôt qu'un remboursement par défaut. Les demandes de clients (`cancelRequestAfterPickup`) alimentent cette file.
4. Aucune commande litigieuse ne reçoit de remboursement automatique.

## 8. Opérations nécessitant votre autorisation

- Déploiement de `functions/` (nécessaire pour mettre C1, I1, I2 en production : `orderRefunds.js` et `orderActions.js` sont dans le même paquet ; lot ciblé suggéré `autoExpireOrders`, `enforceOrderRateLimit`, `cancelOrderCF`, `aiConfirmAction`/outils AZ IA concernés). Aucune règle Firestore à déployer pour ces trois corrections.
- Création de l'outil administratif de décision pour les livraisons ordinaires récupérées (I1/I3).
- Passage de C2 en phase 0 puis en `enforce`.
- Scheduler d'alerte I3.
- Tests sur Samsung (créer une commande, fermer l'application, vérifier la reprise ; annuler avant et après récupération).
