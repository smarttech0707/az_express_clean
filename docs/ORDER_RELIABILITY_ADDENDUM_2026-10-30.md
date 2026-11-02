# Fiabilité des commandes : compléments (vérification I2, outil de litige, C2, I3)

Suite de `docs/ORDER_RELIABILITY_2026-10-30.md`. Tout est local, non déployé, aucune donnée de production modifiée.

## 1. Vérification du dispatch I2

| # | Vérification | Résultat | Preuve |
|---|---|---|---|
| 1 | Fréquence réelle d'`autoExpireOrders` | Planifiée « every 1 minutes ». **Mesurée en production** (journaux Cloud Functions, 40 min, lecture seule) : une exécution par minute à :00 s, retard occasionnel jusqu'à 17 s (démarrages à froid), aucune exécution manquée sur l'échantillon. | `firebase functions:log --only autoExpireOrders` |
| 2 | Compatibilité avec 30/90/150/300/480 s | **Ces âges sont des seuils minimaux, pas des instants garantis.** Un essai n'a lieu qu'à la première exécution qui suit le seuil : le 1ᵉʳ essai tombe entre 30 s et ~90 s (≈ 60 s en moyenne), puis un essai par minute. | Test de cadence (phases 0–56 s, retards 0–17 s) |
| 3 | Scheduler retardé | **Défaut confirmé et corrigé** : le rayon suivait le numéro d'essai ; il suit maintenant aussi l'**âge** de la commande (un premier essai tardif part directement à 5 ou 30 km). Au-delà de 9 min, aucun essai : l'expiration prend le relais. | `dispatchRetry.js`, 3 tests |
| 4 | Nombre réel d'essais | 4 à 5 par commande sur 9 min, jamais plus de 5, jamais deux en moins de 45 s ; 120 passes consécutives → ≤ 5 essais. | Tests unitaires |
| 5 | Commandes déjà `broadcast` | Jamais reprises ni re-diffusées (la reprise ne traite que `pending`) ; elles restent diffusées aux mêmes 5 livreurs jusqu'à l'expiration à 10 min, puis remboursement intégral. Limite connue : pas d'élargissement de rayon une fois diffusée (idem `assigned` à un seul livreur muet). | Émulateur |
| 6 | Élargissement du rayon | Livreur à ~3 km : absent à 2 km, trouvé à l'essai suivant (5 km). | Émulateur |
| 7 | Pas de dispatch concurrent | Trois passes simultanées → un seul essai réservé, une seule attribution ; reprise + dispatch du client simultanés → une seule attribution. | Émulateur (vraies transactions) |
| 8 | Pas de double acceptation | Deux livreurs acceptent en même temps une commande reprise : une seule acceptation. | Émulateur (vraie `acceptOrderCF`) |
| 9 | Pas de double commission | Exactement une commission (200 FCFA pour un budget de 1000) ; le dispatch ne touche à aucun wallet. | Émulateur |
| 10 | Expiration à 10 minutes | `createdAt ≤ now − 600 s` à chaque exécution : expiration entre 10 et 11 min après la création (ou après `requeuedAt`). Expiration + reprise simultanées sur une commande payée avec achats : un seul remboursement de 3 500, aucune reprise après annulation. | Émulateur + test de source |

Limite restante : la requête de reprise lit au plus 50 commandes `pending` (les plus anciennes d'abord) ; sans objet à l'échelle d'Abengourou, à revoir si plus de 50 commandes restaient simultanément en file.

## 2. Outil administratif de litige (`adminOrderDisputeCF`, `functions/adminOrderDisputes.js`)

Callable à deux actions, écriture serveur seule, **aucune écriture Flutter**, aucun écran créé (à brancher après validation).
- `get` (permission `commandes`) : commande, **client** (id, nom), **livreur** (id, nom), statut, **montants réellement encaissés** (wallet payé, budget, shoppingBudget, commission et son payeur), **demande du client** (`cancelRequestAfterPickup`), historique (chronologie, historique des livreurs, derniers événements d'audit). Ni téléphone, ni jeton, ni solde.
- `decide` : décision `maintain` | `close` | `exceptionalCancel`, `requestId` idempotent (16–128 car.), justification ≥ 10 car. obligatoire, limitation de débit.

Décisions :
1. **maintain** : la livraison continue, la demande est rejetée. Aucun mouvement d'argent.
2. **close** : clôture administrative après vérification (livraison constatée). **Aucun mouvement d'argent, statut de la commande inchangé** (trace `adminClosure`).
3. **exceptionalCancel** (**super-admin seul**) : annulation exceptionnelle par le cœur existant `cancelOrderTx`. Remboursement borné à ce que le client a réellement payé (wallet, `isPaid`, hors boutique) : cash et wallet non payé = 0 remboursé ; garde-fou qui refuse tout remboursement supérieur au payé.

Sécurité : seule une commande `picked_up` est concernée ; Marketplace/Boutique renvoyées vers `adminBilling` ; même `requestId` rejoué = aucun effet (`order_dispute_decisions/{sha256}` créé dans la transaction) ; une fois annulée, plus aucune décision ; transaction avec lectures avant écritures ; `logAudit` en succès et en erreur (décision, justification, montants). Aucun remboursement automatique.

**Décisions métier à valider (rien d'inventé) :**
- *Annulation exceptionnelle* : j'ai réutilisé la seule règle existante, celle de toute annulation avant récupération (le client récupère ce qu'il a payé, la commission est rendue au livreur qui l'avait payée). Alternatives : (B) rembourser le client mais conserver la commission d'AZ (le livreur a travaillé) ; (C) rembourser le client et rémunérer le livreur des frais de livraison ; (D) remboursement partiel au montant plafonné choisi par le super-admin.
- *Clôture* : sans paiement du livreur ni changement de statut. Pour qu'une clôture « livraison constatée » crédite le livreur comme `deliverOrderCF`, il faut une règle explicite : (i) crédit selon les règles de livraison normale, sur décision du super-admin ; (ii) paiement manuel hors outil.

## 3. C2 : phase d'observation prête (`functions/tariffObservation.js`)

Journal `tariff_observations/{orderId}` (serveur seul, une écriture par commande) alimenté par `dispatchOrderToDriver` et par la reprise. **Aucun blocage, aucun refus, aucune modification de commande ou de tarif** (`tarifService.js` non modifié). Types observés : `shopping`, `livraison`. Aucune donnée personnelle : ni client, ni nom, ni coordonnées ; seulement type, budget, plancher et prix attendus, nuit / hors zone, distance au centre arrondie.

Détection : `below_minimum` (zone centrale : 500 le jour, 1000 de 20 h à 6 h ; hors ville : 500), `forbidden_late_night` (hors ville > 10 km après 21 h), `off_grid_inside_zone` (zone centrale, prix hors {500, 1000, 1500}).

Faux positifs maîtrisés : tolérance ±10 min autour de 20 h / 21 h (horloge de l'appareil ≠ serveur) ; hors ville seul le plancher de 500 est contrôlé car la distance routière (mesurée par l'application depuis un point qui n'est pas forcément le centre) est inconnue du serveur ; **aucun appel Google Maps** ; heure serveur = heure d'Abidjan (UTC). Faux positifs à attendre : `courses_libres` (budget saisi librement, type `shopping`) peut produire des `off_grid_inside_zone`. Exclus de cette phase : restaurant (budget = total du repas), Marketplace/Boutique, pharmacie, boulangerie.

Coût estimé : zéro lecture supplémentaire (la commande est déjà lue), zéro appel externe, une écriture Firestore par commande déviante (≈ 0,18 $ pour 100 000 écritures ; quelques dizaines par jour au plus), un document de quelques centaines d'octets. Avant un éventuel blocage : au moins 14 jours, tous les écarts examinés à la main, zéro faux positif sur des commandes légitimes ; le passage en blocage reste soumis à votre validation.

## 4. I3 : alertes de commandes bloquées prêtes (`functions/stuckOrderAlerts.js`)

Passe de **lecture seule** toutes les 5 minutes depuis `autoExpireOrders` (après l'expiration et la reprise, sans pouvoir les bloquer). Alerte le super-admin et les sous-admins ayant la permission `commandes` pour une commande `accepted` depuis ≥ 30 min ou `picked_up` depuis ≥ 90 min. **Ne modifie, n'annule, ne réattribue ni ne rembourse jamais une commande, et surtout pas une commande `picked_up`.** Anti-répétition : une alerte par épisode (création atomique de `stuck_order_alerts/{orderId}_{statut}_{instant}`) ; 20 passes successives = une seule alerte ; une ré-acceptation par un autre livreur ouvre un nouvel épisode. Journal `audit_logs` (`stuck_order_alert`) + push FCM. Limite : pas encore de liste d'alertes dans l'interface d'administration.

## 5. Tests

| Suite | Réussis | Ignorés | Échoués |
|---|---|---|---|
| Cloud Functions (`npm test`) | 1 502 | 42 | 0 |
| Émulateur Firestore (7 fichiers `*.emulator.test.js`, exécution groupée) | 24 | 18 (émulateur Auth requis, non lancé) | 0 |
| Règles Firestore (tous les fichiers de `npm run test:rules`, émulateur temporaire) | 399 | 0 | 0 |
| Flutter | non relancé : aucun fichier Dart modifié | | |

Les 42 ignorés de `npm test` = 34 anciens + 8 nouveaux tests d'émulateur (exécutés dans la ligne suivante). Nouveaux : 19 (reprise, cadence), 15 (litige), 10 (tarifs), 7 (alertes), 23 (C1/I1), 6 + 2 (émulateur dispatch et litige), 2 (règles). Un test d'émulateur existant (`driverRatings`, vingt exécutions simultanées) a échoué une fois sur « Transaction is invalid or closed » dans une exécution groupée, puis réussi deux fois isolément et dans l'exécution groupée suivante : comportement connu de l'émulateur sous contention, sans lien avec ces changements. Les tests de transfert simultané (`transferSettlement.emulator`) ont été adaptés : le client ne pouvant plus annuler après récupération, la clôture passe par la décision administrative.

## 6. Risques restants

- Règles métier du litige à valider (§2).
- Pas d'écran d'administration pour le litige ni pour les alertes (appel serveur uniquement).
- `broadcast` / `assigned` sans réponse : pas d'élargissement de rayon avant l'expiration.
- Quota Cloud Run CPU : `adminOrderDisputeCF` ajoute 0,5 CPU à la somme régionale (≈ 119,5 → ≈ 120) ; à vérifier au déploiement.
- Aucun test sur appareil ni sur Firebase de production.

## 7. Opérations nécessitant votre autorisation

- Déploiement des Cloud Functions : `autoExpireOrders`, `enforceOrderRateLimit`, `cancelOrderCF`, `dispatchOrderToDriver`, `adminOrderDisputeCF` (nouvelle) et les outils AZ IA concernés. Aucune règle Firestore à déployer ; aucun index nouveau (requêtes d'égalité + `createdAt`, index existant `status ASC, createdAt ASC`).
- Choix des règles métier du litige puis construction de l'écran d'administration.
- Début effectif de l'observation C2 en production (au déploiement de `dispatchOrderToDriver`).
- Tests Samsung de la reprise (création, fermeture de l'application, nouvelle tentative) et des alertes.


## Compléments (M1–M6)

- Diffusion : `dispatchRetry.js` élargit aussi les commandes déjà en `broadcast` sans livreur (attente 60 s, `expandBroadcast`, nouveaux livreurs ajoutés par arrayUnion, `orders.lastDispatchAtMs`), jamais au-delà de 9 min ni du rayon des paliers.
- Litiges : action `listAlerts` de `adminOrderDisputeCF` (permission `commandes`) ; aucune UI Flutter encore. Décision `resolve` = classement sans clôture ; confirmation de livraison non implémentée. Spécification : `docs/ORDER_DISPUTES_SPEC.md`.
- Tarifs (C2) : parité Dart/Node vérifiée sur 2 400 cas ; seule différence : `routeDistanceKm == 0`. Aucun tarif modifié.
- Test `driverRatings.emulator` : échec intermittent reproduit (4/15) = « Transaction is invalid or closed » de l'émulateur non rejoué par le test ; après correction du test, 30/30. Code de production inchangé.
