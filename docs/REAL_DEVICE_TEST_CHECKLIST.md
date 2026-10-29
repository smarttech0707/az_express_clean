# Checklist de tests sur téléphones — transfert entre livreurs

Statut : **à exécuter dans un projet Firebase de TEST, jamais en production.** Aucun paiement réel :
FeexPay n'est jamais appelé (les soldes de test sont posés à la main dans la console du projet de test,
la recharge Mobile Money n'est pas utilisée). `DELIVERY_SMS_ENABLED` reste à `false` (aucun SMS payant).

## A. Préparation
- [ ] Projet Firebase de test dédié ; fonctions et règles du dépôt déployées **dans ce projet seulement**.
- [ ] Secrets du projet de test : `DELIVERY_PROOF_PEPPER` défini ; `DELIVERY_PROOFS_ENABLED=true` côté fonctions.
- [ ] Application livreur compilée avec `--dart-define=DELIVERY_PROOFS_UI=true --dart-define=APP_BUILD_NUMBER=<n>` ;
      application client avec `DELIVERY_PROOFS_UI=true`.
- [ ] 2 téléphones livreurs (A, B), 1 téléphone client, 1 poste admin (super-admin du projet de test).
- [ ] Comptes de test uniquement : livreur A et B (`isOnline`, même `currentCityId`, GPS autorisé, notifications
      autorisées), client C, super-admin. Wallets : A = 1 000, B = 1 000, C = 5 000 (posés via la console).
- [ ] Zone de livraison de test configurée ; retrait et destination distants d'environ 2–3 km.
- [ ] Noter les soldes de départ : C = ____ A = ____ B = ____ ; `config/az_wallet.totalCommissions` = ____.
- [ ] Autorisations de localisation « toujours » et optimisation batterie désactivée sur A et B.

## B. Commande ordinaire — wallet (prix 1 000 FCFA)
- [ ] C crée la commande, paie par wallet : C = 4 000 (−1 000).
- [ ] A reçoit la notification, accepte : A = 800 (commission 200 prélevée **une seule fois**) ; commande `accepted`,
      `commissionStatus: charged`, `commissionPayerId: A`, `commissionAmount: 200`.
- [ ] Récupération (QR/PIN si activé) ; le suivi GPS du client montre A.
- [ ] Livraison confirmée : A = 1 800 ; ligne `commissions` = 200 ; `totalCommissions` +200 ; aucun document
      `transfer_settlements`.
- [ ] Net A = +800, C = −1 000, AZ = 200.

## C. Commande ordinaire — cash (1 000 FCFA)
- [ ] C choisit cash : wallet C inchangé. A accepte : A = 800. Livraison : wallet A inchangé (800).
- [ ] Net A = 800 (1 000 d'espèces − 200 de commission).

## D. Commande transférée — wallet
- [ ] C paie 1 000 (C = 4 000). A accepte (A = 800), récupère le colis (`picked_up`).
- [ ] A : « Signaler un problème » → motif → demande envoyée. **Notification reçue sur B** (même ville).
- [ ] B ouvre « Remplacements » (icône ⇄), accepte. B est réservé (impossible d'accepter une autre course).
- [ ] B : « Afficher mon code de remise » → QR + PIN. A : scanne le QR (ou saisit le PIN) → remise confirmée.
- [ ] Commande : `driverId = B`, `driverAssignmentVersion = 2`, `transferCount = 1`, `driverHistory` contient A.
      Commission **inchangée** (A, 200, charged). A et B : états `isOnDelivery` corrects (A libre, B en course).
- [ ] **Client** : notification « Nouveau livreur » ; la carte suit désormais B (position, nom, photo).
- [ ] Ancien code : le QR/PIN de remise déjà utilisé est refusé ; A ne peut plus confirmer la livraison.
- [ ] B livre (nouveau code final côté client). Wallets A = 800, B = 1 000 : **rien n'est crédité** ; commande
      `settlementHold: true` ; dossier `transfer_settlements/<id>` créé `pending_review`.
- [ ] Admin : écran « Gains transferts » → dossier affiché (livreurs, tronçons en mètres, parts, commission 200,
      preuves). Valider. Résultat attendu (≈ 40/60 selon les distances relevées) : A = 800 + 200 + part A,
      B = 1 000 + part B ; somme créditée = 1 000 ; net A + net B = 800 ; `settlementHold` levé.
- [ ] Rejouer la validation : aucun mouvement supplémentaire.

## E. Commande transférée — cash
- [ ] Même scénario avec paiement cash (wallets C, A, B inchangés pendant tout le trajet).
- [ ] Après livraison par B : dossier `method: cash`, `holderDriverId: B`. Admin valide → `cash_pending`,
      montant à régulariser B → A affiché ; **aucun wallet modifié**.
- [ ] A voit « Espèces à recevoir », confirme la réception ; admin clôture ; `settlementHold` levé.
- [ ] Vérifier : A = 800 (wallet) + espèces reçues ; B ne détient plus que sa part ; total = 1 000.

## F. Cas négatifs
- [ ] QR d'une autre commande / PIN faux (5 essais → verrouillé) / code expiré (15 min) / code déjà utilisé : refus.
- [ ] Remise non confirmée avant expiration (30 min) : B libéré automatiquement (cron 5 min ou action), A reste
      responsable, validation tardive refusée ; nouvelle demande possible.
- [ ] B déjà en course ou suspendu : ne peut pas accepter. Livreur d'une autre ville : pas de demande reçue.
- [ ] Deux livreurs candidats acceptent en même temps : un seul gagne.
- [ ] **Annulation par le client pendant un transfert** (B réservé) : B immédiatement libre, transfert `cancelled`,
      QR/PIN inutilisable, C remboursé une fois, commission rendue à A une fois (A = 1 000).
- [ ] 3ᵉ transfert refusé (limite 2) ; commande marketplace/boutique : transfert refusé (`PARTNER_ORDER_REVIEW`).
- [ ] GPS désactivé/périmé à la remise : dossier créé **sans part proposée** (revue administrative obligatoire),
      correction possible uniquement avec justification et somme = prix.

## G. Notifications (à constater sur écran verrouillé)
- [ ] Demande de remplacement (candidats) ; changement de livreur (client) ; remise en recherche (client).
- [ ] Aucun SMS envoyé (`DELIVERY_SMS_ENABLED=false`).

## H. Version minimale (non bloquant)
- [ ] Sans document `config/app_versions` : aucun message. Avec `{driver:{minBuild: n+1, enforce:false}}` : message
      « Mise à jour disponible » fermable. Avec `enforce:true` : dialogue bloquant. Remettre à l'état initial.

## I. Critères d'arrêt
Stopper et ne pas déployer en production si : un solde diffère des valeurs attendues, une commission est prélevée
deux fois, une preuve utilisée ou annulée reste valide, un livreur reste réservé après annulation/expiration, ou un
crédit est appliqué avant validation administrative.

## J. Relevé à joindre au rapport
Soldes avant/après de C, A, B ; contenu de `orders/<id>`, `delivery_transfers/<id>`, `transfer_settlements/<id>` ;
captures des notifications et du suivi ; heure de chaque étape.
