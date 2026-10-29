# Transfert de livraison entre livreurs (Phase 2)

Statut : **développé et testé en local, non déployé**. Aucun drapeau de production activé.

## Cas 1 — avant récupération du colis
- `releaseOrderBeforePickupCF` (`functions/driverRelease.js`) : libère une course `accepted`.
  Commission remboursée une fois (montant tracé), commande remise `pending`, livreur exclu.
- `declineLegacyOrderCF` (`functions/driverDecline.js`) : refus d'une mission `assigned`/`broadcast`
  avant acceptation. Aucun mouvement de wallet (commission prélevée seulement à l'acceptation).
- UI : bouton « Signaler un problème » (`driver_dashboard.dart`).

## Cas 2 — après récupération (`deliveryTransferCF`, `functions/driverTransfer.js`)
Une seule Cloud Function à `action` (request, accept, decline, cancel, prepareHandover,
confirmHandover) pour ne pas consommer de quota Cloud Run CPU supplémentaire.

1. A (`picked_up`, responsable) demande un remplaçant → `delivery_transfers/{orderId_n}`,
   verrou `orders.activeTransferId`, max 2 transferts (`transferCount`), 6 demandes (`transferAttempts`).
2. Candidats = livreurs en ligne, disponibles, non suspendus, même ville. Premier accepté gagne
   (transaction) ; B est réservé (`isOnDelivery`). Demande valable 10 min, remise 30 min.
3. B émet la preuve `handover` (moteur QR/PIN existant, liée à A et à la version d'affectation).
   A la valide (QR ou PIN). Échange atomique : `driverId`, `driverAssignmentVersion + 1`, historique,
   états des deux livreurs, preuve consommée, preuve de livraison de A révoquée.
4. La version incrémentée invalide la preuve de livraison, les accès destinataire et l'état SMS de A.
   Le nouveau livreur doit obtenir une nouvelle preuve de livraison.
5. Expiration paresseuse : une demande expirée est fermée à la prochaine demande ou action
   (aucun scheduler ajouté).

## Finances (décision métier en attente)
- Aucune seconde commission ; `commissionPayerId/Amount/Status` inchangés ; A n'est pas remboursé.
- `settlementHold` : à la livraison, ni A ni B n'est crédité (`deliverOrderCF`, `payOrderFromWalletCF`) ;
  le gain est noté `heldDriverEarning`, `settlementStatus: pending_admin_review`.
- La ligne `commissions` est écrite au nom du payeur d'origine avec le montant réellement prélevé.
- La dernière position connue de A est copiée dans le transfert (non vérifiée) : aucune distance inventée.
- Course avec `shoppingBudget` : transfert automatique refusé (`SHOPPING_BUDGET_REVIEW`).

## Version minimale
`config/app_versions` : `{ driver: { minBuild, enforce, message } }`. Sans `enforce: true`, simple
recommandation. Build injecté par `--dart-define=APP_BUILD_NUMBER=<n>` (inconnu = jamais bloqué).
La branche Firestore `assigned → accepted` reste ouverte : voir `DRIVER_ACCEPT_RULE_MIGRATION.md`.

## Avant déploiement
Déployer les fonctions (`deliveryTransferCF`, `declineLegacyOrderCF`, `releaseOrderBeforePickupCF`,
`acceptOrderCF`) puis les règles ; activer `DELIVERY_PROOFS_ENABLED` (+ `DELIVERY_PROOFS_UI` à la
compilation) ; ajouter `APP_BUILD_NUMBER` aux builds ; décider du partage des gains.

## Phase 3 — partage des gains

### Calcul (`functions/earningsSettlement.js`, algorithme `progress_toward_destination_v1`)
- Distance utile d'un livreur = progression à vol d'oiseau vers la destination entre son point de
  prise en charge et son point de remise, jamais négative : un détour ou un recul ne rapporte rien.
- Points : retrait et destination de la commande ; point de remise = milieu des positions GPS des deux
  livreurs capturées par le serveur à la remise confirmée (QR/PIN), seulement si fraîches (≤ 3 min) et
  distantes de ≤ 500 m. Sinon `trusted:false` : aucun point inventé.
- Montant réparti = prix − commission tracée. Arrondi FCFA au plus fort reste : la somme est exacte.
- Le payeur de la commission (déjà débité à l'acceptation) est remboursé en tête : le total versé aux
  livreurs est égal au prix payé, AZ ne conserve que la commission prélevée. Ex. 1000/200, A 4 km, B 6 km :
  A reçoit 320 + 200, B 480 (net A 320).
- Données insuffisantes (GPS, commission non tracée, preuve absente, distance nulle) : aucune part
  proposée, validation administrative obligatoire.

### Règlement (`transfer_settlements/{orderId}`, `settleTransferEarningsCF`, super-admin)
- Créé à la livraison (ou au paiement différé wallet) en `pending_review`, objectif 24 h (`dueAtMs`,
  badge « en retard » dans l'écran admin). Aucune tâche d'alerte planifiée : voir limites.
- `approve` : wallet = crédit atomique de chaque livreur (mouvement `transfer_settlement_<order>_<driver>`,
  impossible à rejouer) ; cash = aucun mouvement de wallet, ouverture du règlement entre livreurs.
- Répartition corrigée : justification ≥ 10 caractères, somme exactement égale au prix payé.
- Cash : le livreur final encaisse ; montants à régulariser par créancier ; confirmation de réception
  par chaque créancier, puis `closeCash` par l'administrateur (dérogation justifiée possible).
  `settlementHold` n'est levé qu'à la clôture. Aucun débit automatique du livreur final.

### Expiration
`expireDeliveryTransfers` (cron 5 min, 1 instance, 0,5 CPU) + expiration à l'action : B libéré,
verrou levé, A reste responsable, validation tardive refusée, nouvelle recherche possible.

### Préparation de la fermeture `assigned → accepted` (non appliquée)
Mesure en lecture seule avant toute fermeture : commandes `accepted`/`picked_up`/`delivered` récentes
dont `commissionStatus` est absent = acceptées par une ancienne version. Fermer seulement quand ce
nombre reste nul sur une période choisie ET que `config/app_versions.driver.enforce` a été activé.

## Phase 4 — corrections avant tests réels
- **Annulation pendant un transfert** (`cancelOrderTx`, donc client, AZ IA et tout appelant) : dans la même
  transaction, le transfert ouvert passe `cancelled` (`closeReason: order_cancelled`, historique conservé),
  le remplaçant B est libéré (`isOnDelivery`/`pendingOrderId`), la preuve de remise active est révoquée et
  le verrou `activeTransferId` levé. Remboursements inchangés : client une fois, commission au payeur d'origine
  une fois. Testé en mémoire et sur l'émulateur Firestore (annulations simultanées, annulation × remise).
- **Commandes marketplace/boutique** : transfert refusé (`PARTNER_ORDER_REVIEW`) car `budget` y est le prix du
  produit ; les autres commandes de partenaire (`sellerId`) ne reçoivent jamais de part automatique.
- **Corrigé** : pour les commandes marketplace/boutique créées après `docs/MARKETPLACE_BOUTIQUE_BILLING.md`, le client paie
  produits + livraison et le livreur est crédité des frais à la livraison. Les commandes historiques gardent l'ancien
  comportement (test « ÉTAT ACTUEL »).
- Checklist terrain : `docs/REAL_DEVICE_TEST_CHECKLIST.md`.
