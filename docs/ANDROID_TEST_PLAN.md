# Plan de tests Android — Samsung SM-A115F et Infinix X6525D

Statut : **à exécuter uniquement sur le projet Firebase de TEST** (voir `test-env/README.md`). Jamais en production,
aucun paiement réel, aucun SMS payant. Complète `docs/REAL_DEVICE_TEST_CHECKLIST.md` (transferts, scénarios D à F
détaillés) et `docs/MARKETPLACE_BOUTIQUE_BILLING.md` (règles de facturation).

## 0. Préparation
- [ ] Projet de test créé par vous, `node test-env/verify-isolation.js` → « Isolation validée ».
- [ ] Fonctions et règles déployées **dans le projet de test seulement** (`firebase deploy --project <id-test> ...`).
- [ ] `node test-env/seed-test-data.js --project <id-test> --confirm-project <id-test>` exécuté.
- [ ] APK de test installé (`test-env/install-test-apk.ps1`) sur les deux téléphones : paquet `com.azexpress.app.test`
      (l'application de production, si présente, n'est ni remplacée ni utilisée).
- [ ] Rôles : **Samsung SM-A115F = livreur A + client** (deux sessions successives), **Infinix X6525D = livreur B**,
      admin sur un ordinateur (navigateur, projet de test) ou sur l'un des deux téléphones.
- [ ] Localisation « toujours », notifications autorisées, optimisation batterie désactivée sur A et B.
- [ ] Soldes de départ (seed) : client **20 000**, A **5 000**, B **5 000**, vendeur **0**, stock `Riz 5 kg (test)` **10**.
      Relever : client = ____ A = ____ B = ____ vendeur = ____ stock = ____.
- [ ] Notation : **P** = prix de livraison affiché au client, **c** = commission (100 si P < 1 000, sinon 200).

## 1. Scénarios (16)

| # | Scénario | Actions | Résultat attendu (solde / état) |
|---|---|---|---|
| 1 | Connexion client | Téléphone `+2250100000001` + mot de passe de test | Accueil client, wallet **20 000** |
| 2 | Connexion livreur A | Identifiant `test-livreur-a`, passer « en ligne », GPS actif | Tableau de bord livreur, wallet **5 000**, `isOnline=true` |
| 3 | Connexion livreur B | Identifiant `test-livreur-b`, en ligne | Wallet **5 000**, `isOnline=true` |
| 4 | Création de commande | Client : livraison standard, paiement **wallet**, ~2–3 km | Client = **20 000 − P** ; `orders/<id>` `pending` puis `assigned`/`broadcast` ; A (et B) notifiés |
| 5 | Acceptation avec commission | A accepte | A = **5 000 − c**, prélevée **une seule fois** ; `status=accepted`, `commissionStatus=charged`, `commissionPayerId=A`, `commissionAmount=c` ; `audit_logs` `accept_order` |
| 6 | Récupération | A marque « récupéré » (QR/PIN si activé) | `status=picked_up`, `pickedUpAt` renseigné ; le client voit A sur la carte |
| 7 | Demande de remplacement | A : « Signaler un problème » → motif | `delivery_transfers` créé ; **notification reçue sur B** ; A reste responsable |
| 8 | Acceptation par B | B ouvre « Remplacements » et accepte | B réservé (ne peut pas accepter autre chose) ; **B = 5 000 (aucune commission)** ; A inchangé |
| 9 | Remise QR/PIN | B affiche son code ; A scanne (ou saisit le PIN) | `driverId=B`, `driverAssignmentVersion=2`, `transferCount=1`, commission **inchangée (A, c, charged)** ; A libre, B en course ; ancien code refusé |
| 10 | Suivi GPS du nouveau livreur | Client observe la carte pendant que B roule | Notification « Nouveau livreur » ; la carte suit **B** (position, nom, photo), plus A |
| 11 | Livraison au destinataire | B livre avec le code final du client (photo + GPS) | `status=delivered` ; **aucun crédit immédiat** ; `settlementHold=true` ; `transfer_settlements/<id>` `pending_review` |
| 12 | Vérification des gains | Relever tous les soldes | Client = 20 000 − P ; A = 5 000 − c ; B = 5 000 ; `commissions` = c ; **rien de crédité avant validation** |
| 13 | Validation admin | Admin : « Gains transferts » → valider (puis rejouer) | Parts créditées à A et B ; **gain net A + B = P − c** ; `settlementHold` levé ; rejeu = aucun mouvement |
| 14 | Commande Marketplace | Client (AZ IA ou écran Marketplace) : `Téléviseur (test)` 5 000, wallet | Résumé « 5 000 + livraison P = **5 000 + P** » ; client = −(5 000+P) ; vendeur **+5 000** ; A accepte : −c (sur P seulement) ; livraison : A **+P** ; vendeur non recrédité ; transfert refusé (`PARTNER_ORDER_REVIEW`) |
| 15 | Commande Boutique | Écran Boutique : `Riz 5 kg (test)` ×1 | Détail **5 000 + 500 = 5 500** (jamais 5 000 débités sous un total de 5 500, ni l'inverse) ; client −5 500 ; vendeur +5 000 ; **stock 10 → 9** ; A accepte −100 ; livraison A **+500** |
| 16 | Annulation et remboursement | Voir 16a à 16d | Voir ci-dessous |

### 16. Annulations (une commande Boutique ou Marketplace par cas ; relever stock et soldes)
- [ ] **16a – avant récupération** : le client annule après acceptation par A. Client remboursé **intégralement**
      (produits + livraison), vendeur repris de 5 000, commission rendue à A, **stock inchangé (9, jamais restitué automatiquement)**.
- [ ] **16b – après récupération** : le client annule (`picked_up`). Produits remboursés (5 000), vendeur repris, **frais 500 retenus**
      (`orders.deliveryFeeHold.status=pending_admin_review`), commission non rendue, stock inchangé. Écran admin « Facturation » :
      décider `refundClient` / `payDriver` / `retain` ; rejeu sans effet.
- [ ] **16c – restitution du stock** (admin, après constat physique) : action `confirmStockReturn`, motif `non_delivery` (colis jamais
      récupéré) ou `product_returned` (retour constaté chez le vendeur) → stock +1 **une seule fois** ; rejeu sans effet ;
      `non_delivery` refusé si le colis a été récupéré.
- [ ] **16d – double tap / rejeu** : double appui sur « Annuler » ou « Payer » → un seul mouvement d'argent.

## 2. Cas de non-régression financière (en plus des 16)
- [ ] Ancienne commande « historique » (créée par une ancienne application) : acceptation refusée (`LEGACY_PARTNER_ORDER`, message
      « en cours de traitement »), livreur non débité ; visible dans l'écran admin « Anciennes commandes à résoudre » ; clôture →
      remboursement des produits.
- [ ] Solde insuffisant (client à 1 000, commande de 5 500) : refus `SOLDE_INSUFFISANT`, rien débité, stock intact.
- [ ] Livreur A à solde < c : acceptation refusée (`CREDIT_INSUFFISANT`), aucune commission, course intacte.

## 3. Critères d'arrêt
Stopper et ne pas déployer en production si : un solde diffère des valeurs attendues ; une commission est prélevée deux fois ;
un stock est restitué sans action admin ; un crédit est appliqué avant validation ; un livreur reste réservé après annulation ;
une commande historique est acceptée avec commission ; un écran affiche un total différent du montant débité.

## 4. Relevé à joindre
Soldes avant/après (client, A, B, vendeur) ; stock avant/après ; `orders/<id>`, `boutique_orders/<id>`, `delivery_transfers/<id>`,
`transfer_settlements/<id>` ; captures des notifications, de la carte (étape 10) et des écrans de résumé (14, 15) ; heure de chaque étape.
Ne jamais joindre de mot de passe ni de clé.
