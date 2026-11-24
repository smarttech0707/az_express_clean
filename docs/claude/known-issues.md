# Problèmes connus et informations à ne pas croire sans vérifier (2026-10-27)

Établi lors de la réorganisation de CLAUDE.md. L'archive (`history/CLAUDE_full_2026-10-27.md`) est conservée intégralement et **n'a pas été corrigée** : elle reflète l'état de juillet 2026 (Master Prompts 1→64, plus la série 113→136 insérée dans des sections génériques). Vérifier dans le code avant de s'appuyer sur un chiffre.

## A. Informations obsolètes ou contradictoires dans l'archive

| Affirmation de l'archive | État vérifié le 2026-10-27 | Source de vérité |
|---|---|---|
| Projet Firebase `az-express-clean` (16 mentions) | Projet actif `az-express-b0469` | `.firebaserc`, `firebase.json` |
| « 30/53 fonctions déployées, facturation Cloud Build bloquée » (prompts 65-83) | Débloqué ; 57-58 fonctions déployées (prompt 122, puis ajouts) | `firebase functions:list` |
| Runtime Node 20 déprécié, `firebase-functions` ancien | `nodejs22`, `firebase-functions` 7.3.2 | `firebase.json`, `functions/package.json` |
| « Zéro commit git, aucun remote » (prompt 38) | Remote `origin` existant, historique de commits (derniers : TestFlight build 13) | `git log`, `git remote -v` |
| iOS : bundle ID `com.example.azExpressClean`, pas de Podfile (prompts 62, 64) | Bundle ID de la cible app = `com.azexpress.app`, `ios/Podfile` et `codemagic.yaml` existent (seul `RunnerTests` garde `com.example...`) | `ios/`, `codemagic.yaml` |
| Version `1.0.0+1` | `1.0.10+11` ; des `.aab` 1.0.6 à 1.0.8+ existent à la racine | `pubspec.yaml` |
| Canal Flutter beta | Canal stable (3.44.5) | `flutter --version` |
| Tarif Express 700 jour / 1000 nuit (prompts 45-51, 130) | **1000 jour / 1500 nuit** (prompt 64) | `lib/services/tarif_service.dart`, `functions/tarifService.js` |
| Commission livreur prélevée à l'acceptation ET à la livraison | **Une seule fois, à l'acceptation** (prompt 75) | `functions/orderActions.js` |
| Pharmacies « sans flux d'inscription » | Flux `pharmacie_register.dart` → `pharmacie_requests` réel, réparé au prompt 74 | `firestore.rules` |
| Immobilier : `real_estate_categories` dans Firestore | Schéma mort : types codés en dur (`_propertyTypes`) | `agent_dashboard_screen.dart` |
| Menus restaurant : collection racine `menus` ou sous-collection `menus` | Source unique : `restaurants/{id}/menu` (prompt 63) | `restaurant_menu.dart` |
| Classement livreurs « sur les 500 dernières commandes » | Plafond inexistant dans le code (prompt 79) | `admin_drivers_ranking.dart` |
| `support_tickets` / `marketplace_reports` sans UI admin (prompts 13, 72-76) | `admin_support_page.dart` existe depuis le prompt 78 | `lib/screens/admin/` |
| « CinetPay » comme prestataire | FeexPay, partout (corrigé au prompt 69) | `functions/index.js` |
| Compteurs : 45/52/53/57 fonctions ; 104→248 tests Node ; 5/7/8 avertissements d'analyse | Ces nombres changent à chaque passe : recompter | `npm test`, `flutter analyze` |
| « Création de commande wallet probablement bloquée par `isPaid == false` inconditionnel » (prompt 80, annexe) | **Tranché le 2026-10-27 : ce n'est plus le cas dans le code local.** La règle autorise `isPaid:true` à la création pour un paiement wallet avec débit lié (`walletDebitMatchesPaidOrder` + `lastPaidOrderId`). Voir section C bis | `firestore.rules` l.108-121 et l.534-538 |

Les paragraphes de l'archive commençant par « Verdict », « READY PILOT », « NO GO », « BLOCKED » sont des **états à un instant donné**, jamais l'état courant.

## B. Travail récent absent de l'archive (à lire dans `docs/` et `git log`)

CLAUDE.md s'arrêtait au prompt 64 (série 2026-07-21). Depuis : suppression de compte partenaires (`docs/ACCOUNT_DELETION_*.md`), preuves de livraison QR/PIN et SMS (`docs/DELIVERY_PROOFS_*.md`), QR partenaires (`docs/PARTNER_QR_*.md`), publication/distribution Android et hosting (`docs/DISTRIBUTION_*.md`, `ARCHITECTURE_PUBLICATION_V2.md`, `PUBLICATION_STANDARD_V1.md`), réinitialisation de mot de passe, comptes partenaires admin, publication Marketplace (`functions/marketplacePublishing.js`, `functions/passwordReset.js`, `functions/adminPartnerAccounts.js`), flux E-Kbine (`functions/ekbineFlow.js`), TestFlight builds 12-13 (Codemagic). Ces travaux ne sont documentés que dans leurs fichiers et dans git.

## C. Risques ouverts réels (non corrigés, à confirmer avant action)

Financier / sécurité
- Tarification livraison calculée côté client pour les écrans Flutter, sans revalidation serveur (un client modifié peut envoyer un `budget` arbitraire).
- Boutique : pas d'annulation/remboursement de `boutique_orders` ; remboursement 48 h déclenché à l'ouverture de l'écran, pas par scheduler.
- RBAC sous-admin : `permissions` non appliqué dans `firestore.rules`.
- `livreurs/{id}.wallet` et KYC `driver_photos` lisibles par tout utilisateur authentifié.
- Création de compte livreur par un patron de flotte (`fleet_dashboard.dart`) probablement en `permission-denied`.
- Aucune vérification d'unicité téléphone/pièce d'identité à l'inscription livreur.
- `enforceAppCheck` non activé ; clé reCAPTCHA web manquante.
- `AuthService.toE164()` : le 0 initial d'un numéro local à 10 chiffres est retiré (numéro trop court).
- Cash produit remis au marchand par le livreur : suivi via `merchantCashSettled` mais sans rapprochement automatique.
- Vulnérabilités npm transitives (`firebase-admin`) signalées au prompt 62 : à re-vérifier (`npm audit`).

Fonctionnel
- Trois systèmes Immobilier non consolidés (`locations`, `residences`, `real_estate_listings`) ; AZ IA ne voit que le dernier.
- Deux services de suivi de livraison dupliqués ; deux moteurs de tarification (legacy `DeliveryService` partiellement conservé).
- Marketplace : produit à exemplaire unique achetable plusieurs fois via AZ IA (pas de statut « vendu »).
- Pas de suspension d'un client ; pas de réattribution automatique de livreur après attribution.
- Aucune préférence de notification, un seul appareil FCM par compte.
- `Image.network` brut (~24 fichiers) ; pas de purge/TTL sur `audit_logs`, `security_events`, `request_logs`, `ai_conversations`.
- ~30 écrans admin lisent des collections sans `.limit()` (certains font des totaux : ne pas borner sans analyse).
- Mode sombre partiel (écrans à couleurs statiques) ; contraste blanc/orange sous AA ; accessibilité partielle.
- Aucune sauvegarde Firestore planifiée visible dans le dépôt.
- Aucun test device/émulateur exécutable depuis certains environnements ; les tests `rules-tests` nécessitent Java.

## C bis. Vérification ciblée `isPaid` / création de commande wallet (2026-10-27, lecture seule + émulateur local)

**Règle locale (`firestore.rules`)** : `orders` create (l.511-538) exige `budget` entier ≥ 500 et `status == 'pending'`, et accepte soit `isPaid == false`, soit `isPaid == true` avec `paymentMethod == 'wallet'` ET `walletDebitMatchesPaidOrder(orderId)` (l.108-121) : le document `clients/{uid}` doit passer, dans la même transaction, de `wallet` à `wallet − montant` avec `lastPaidOrderId == orderId`. Montant = `budget + shoppingBudget` (ou `totalAmount` pour `sellerType == 'boulangerie'`). Le risque décrit en 2026-07 (`isPaid == false` inconditionnel) **n'existe plus** dans le fichier local.

**Écrans qui débitent le wallet et créent la commande dans une transaction** (tous écrivent `lastPaidOrderId`) :
| Écran | Débit vs règle | Verdict |
|---|---|---|
| `livraison_screen.dart` / `delivery_order_service.dart` (l.75-92) | `price + shoppingBudget` | conforme |
| `courses_screen.dart` (l.415, 543) | `shoppingBudget + _deliveryFee` | conforme |
| `restaurant_menu.dart` (l.155, 210) | `orderTotal` = `budget` | conforme |
| `colis_page.dart` (l.162, 190) | `_price` = `budget` | conforme |
| `blanchisserie_page.dart` (l.104, 143) | `_totalPrice` = `budget` | conforme |
| `boulangerie_order_page.dart` (l.1279, 1320) | `totalAmount` | conforme |
| `eau_boissons_page.dart` (l.141, 189-190, 226) | débit `_totalPrice + _deliveryFee` ; commande `budget: 500` codé en dur + `shoppingBudget: _totalPrice` | conforme **tant que `_deliveryFee == 500`** (défaut l.26) (avant correction ; `budget` = `_deliveryFee` depuis le 2026-10-27) |
| `create_order.dart` (l.373, 391, 430-431, 488) | débit **`deliveryFee` seul** ; commande `budget: deliveryFee` + `shoppingBudget` saisi par le client | **non conforme si `shoppingBudget > 0`** (avant correction ; corrigé localement le 2026-10-27) |
| `pharmacie_garde.dart` | pas de débit à la création (`isPaid:false`), règlement post-livraison | hors sujet |
| `courses_libres.dart` | `isPaid: false` | hors sujet |

**Défaut 1 — `create_order.dart`, wallet avec « Budget total des articles » : CORRIGÉ LOCALEMENT (2026-10-27).**
- Correction : le contrôle de solde et la transaction utilisent `totalAmount = deliveryFee + shoppingBudget` (même calcul que `courses_screen.dart`) ; `lastPaidOrderId` et `budget` / `shoppingBudget` de la commande inchangés ; avec `shoppingBudget = 0` le débit reste égal aux frais.
- Fichier : `lib/screens/client/create_order.dart` (contrôle de solde l.383-395, transaction l.484-495).

**Défaut 2 — `eau_boissons_page.dart`, `budget` codé en dur à 500 : CORRIGÉ LOCALEMENT (2026-10-27).**
- Correction : `"budget": _deliveryFee` (l.189) ; le montant enregistré égale le débit (`_totalPrice + _deliveryFee`). Chemin cash non modifié.

**Tests réussis (corrections wallet)** : `rules-tests/wallet-order-creation.test.js` 14/14 (émulateur Firestore local : wallet avec / sans budget articles, solde insuffisant, solde exact, cash, eau et boissons frais 500 et 700, ancien comportement toujours refusé, aucun débit partiel, rejeu, transactions concurrentes, un débit pour deux commandes) ; `npm run test:rules` 235/235 ; `flutter test` 914/914 ; `flutter analyze` sans nouveau message sur les deux fichiers.

**Réserves (non effectuées)** : validation sur appareil (aucun test d'écran Flutter pour ces parcours, la transaction est reproduite dans le test) ; production non vérifiée (`firestore.rules` local non commité, version déployée inconnue) ; corrections ni déployées ni commitées.

**Risque ouvert — frais Eau et Boissons < 500 FCFA.** La règle exige `budget >= 500` (`firestore.rules` l.513-514) et aucune borne n'existe côté écran : si `_deliveryFee` passait sous 500, toute commande (cash comprise) serait refusée. Source du réglage (lecture seule, 2026-10-27) : `app_config/eau_boissons`, champ `deliveryFee`, lu par `_loadConfig()` (l.93-110) dans un `try/catch` silencieux. Aucun code du dépôt n'écrit ce document. La règle `app_config` n'autorise la lecture qu'à l'admin (et au document `blanchisserie` pour les clients, l.1260-1263) : un client reçoit `permission-denied`, avalé, donc `_deliveryFee` reste à 500 pour les clients. Le risque est latent : il se réaliserait si ce document était créé avec une valeur < 500 et lisible par le client (ou lu par un admin). Correction minimale recommandée, non appliquée : borner la valeur lue (`max(500, valeur)`). Données de production non consultées.


## C ter. Première connexion des partenaires créés par l'admin (étapes B et B2, 2026-10-27, local, NON déployé)

- Mécanisme : `manageAdminPartnerAccount` génère un mot de passe TEMPORAIRE (crypto, 12 caractères), renvoyé une seule fois à l'admin ; seul son hachage est gardé dans `partner_provisioning/{uid}` (réservé aux fonctions). Une revendication `partnerMustChangePassword` est posée sur le compte. À la connexion (vendeur, boulangerie, restaurateur), `PartnerFirstPasswordPage` impose le changement ; `completePartnerFirstPasswordChange` change le mot de passe Auth côté serveur (verrou transactionnel anti double changement), lève le drapeau serveur, révoque les sessions puis retire la revendication ; son mode `statusOnly` confirme l'état et répare une revendication périmée. Comptes historiques : aucun changement imposé.
- **B2 — protections serveur appliquées localement (non déployées)** :
  - `firestore.rules` : helper `partnerActivated()` (journal serveur `partner_provisioning/{uid}` fait AUTORITÉ s'il existe — couvre un jeton ANCIEN sans revendication et ne pénalise pas une revendication périmée après changement ; sinon la revendication du jeton) ajouté aux ÉCRITURES du propriétaire sur `sellers` (+ `wallet_transactions`), `boulangeries` (+ `menu_items`), `restaurants/{id}` (2 règles) et `restaurants/{id}/menu`, et aux 2 branches partenaire de `orders`. Lectures et branches admin inchangées.
  - `initiateWithdrawal` (functions/index.js) et `manageProfessionalSubscription` (functions/professionalSubscriptions.js) : garde `assertPartnerActivated` (functions/partnerActivationGuard.js), même logique d'autorité, placée avant toute validation, limitation de débit ou débit. Aucun effet sur les autres catégories d'utilisateurs.
  - Tests : `rules-tests/partner-activation.rules.test.js` (52, inclus dans `npm run test:rules`), `functions/test/partnerActivationGuard.test.js`, et bout en bout sur émulateurs avec vrais jetons et vraies règles : `functions/test/partnerActivation.e2e.emulator.test.js` (`AZ_E2E_RULES=1`, config d'émulateur avec les règles).
- **B3 (2026-10-27, local, non déployé) — contournements fermés** : annonces Marketplace du vendeur (`marketplace_products`, mise à jour et suppression ; les compteurs de vues/favoris ouverts à tous restent inchangés), conversations Marketplace côté VENDEUR uniquement (document de conversation et réponse aux acheteurs ; le côté acheteur est inchangé), écritures propriétaire sur `boutique_products` et `vehicle_listings`, `publishMarketplaceProduct`, `republishMarketplaceProduct` et `initiateFeexPayPayment` (garde placée avant toute validation, limitation de débit ou transaction ; aucun montant, solde, webhook ni statut de paiement modifié). Tests : `rules-tests/partner-activation-b3.rules.test.js` (42), `functions/test/partnerActivationGuard.test.js`, `functions/test/partnerActivation.e2e.emulator.test.js` (vrais jetons, vraies règles).
- **B4 (2026-10-27, local, non déployé) — Cloud Storage** : les écritures (création, remplacement, suppression) d'un partenaire non activé sont refusées sur `seller_photos`, `boulangerie_logos`, `vehicle_listings` (images, vidéos), `vehicle_seller_profiles` (journal serveur prioritaire, jeton ancien refusé) et sur `restaurant_logos`, `restaurant_menu_items`, `restaurant_covers`, `marketplace` (photos d'annonce), `mp_chat_audio` (côté vendeur) (revendication du jeton seule). Lectures, chemins admin, acheteurs, clients ordinaires et comptes historiques inchangés. Tests : `rules-tests/partner-activation.storage.rules.test.js` (93, dans `npm run test:storage`, exécutés en série).
- **Limite Storage à connaître** : les règles Cloud Storage n'autorisent que 2 documents Firestore distincts par évaluation (documentation Firebase) et `isAuth()` en consomme déjà un (`account_tombstones`). **L'émulateur Storage n'applique pas cette limite** (sonde : 3 documents acceptés) : un dépassement ne se verrait qu'en production. Le budget est donc verrouillé par un test STATIQUE (mutation vérifiée). Conséquence : sur les chemins qui lisent déjà un autre document de propriété (restaurants → `restaurant_owners`, Marketplace → `marketplace_products` / `marketplace_chats`) seule la revendication du jeton peut être consultée ; un jeton émis AVANT une réinitialisation admin (sans revendication) reste accepté sur ces chemins jusqu'à son expiration (≤ 1 h), et une revendication périmée après activation est refusée jusqu'à la reconnexion. Pour fermer cette fenêtre il faudrait écrire un indicateur d'activation dans `restaurant_owners` (modification des fonctions de provisionnement, non faite).
- **Existant à vérifier en production (hors périmètre)** : `restaurant_menu_items` et `restaurant_covers` évaluent `isAdmin()` avant la preuve de propriété, soit 3 documents (tombstone, admins, restaurant_owners) pour un propriétaire : au-delà de la limite de 2, le téléversement du propriétaire pourrait échouer en production. Non modifié.
- **Contournements ENCORE possibles pour un compte non activé (après B4, non corrigés, hors périmètre)** : `marketplace_reports` et `marketplace_favorites` (opérations d'utilisateur ordinaire) ; fonctions déclenchables avec un rôle de client (`payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `createEventReservationCF`, `requestPropertyVisit`, `requestAccountDeletionCF`…) car elles agissent sur le compte CLIENT de l'appelant, que ces trois rôles n'ont pas ; fonctions Ekbine, QR (`getPartnerQr`, `resolvePartnerQr`, `setPartnerQrManager`, hors périmètre) et pharmacie. Les écritures du restaurateur sur `orders` ne passent par aucune règle propriétaire trouvée (restaurantId ≠ uid).
- Autres limites : un jeton émis avant la pose de la revendication reste valide jusqu'à 1 h, mais les règles et les fonctions consultent le journal serveur ; la transmission du mot de passe temporaire repose sur l'admin (affichage unique) ; les revendications ne sont pas testables contre la falsification de jeton sur émulateur (jetons non signés) — en production elles sont signées par Firebase Auth.
- **B5 (2026-10-27, local, non déployé) — Storage : budget de 2 documents et fenêtre de jeton ancien** : `storage.rules` restructuré pour que chaque instruction tienne en 2 documents Firestore dans le PIRE cas (tombstone de `isAuth()` + 1). Propriétaire et administrateur séparés, discriminateur sans document : e-mail `@az-restaurant.ci` (restaurants) ou UID du chemin (boulangerie). Restaurants : `restaurant_owners/{uid}` prouve propriété ET activation via `mustChangePassword` (présent = fait foi ; absent = revendication du jeton, compatible comptes historiques). **Corrige l'existant noté en B4** (3 documents pour `restaurant_menu_items`/`restaurant_covers`/`restaurant_logos`). Tests : `partner-activation.storage.rules.test.js` (120, avec analyseur statique du budget, mutation vérifiée).
  - **Fonctions NON modifiées (autorisation requise)** : proposition validée en copie de travail dans `docs/claude/proposed-functions/` (`adminPartnerAccounts.js`, `partnerFirstLogin.js`) : projection écrite dans le même lot atomique que le journal `partner_provisioning/{uid}` (qui reste la SEULE autorité). Tant qu'elle n'est pas appliquée, les restaurateurs retombent sur la revendication (fenêtre ≤ 1 h après réinitialisation). Aucune migration de données. Ordre : fonctions → règles → applications. L'étape D (réinitialisation) devra écrire journal ET projection ensemble.
  - **Fenêtre résiduelle NON fermable sans refonte** : `marketplace` (photos) et `mp_chat_audio` (côté vendeur) lisent déjà 1 document de preuve (produit / conversation) ; ajouter le journal dépasserait 2 documents. Options : accepter et documenter (≤ 1 h, jeton ancien seul), ou chemin `marketplace/{sellerUid}/{productId}/…` (changement client + fonctions + migration des fichiers existants : décision requise).
  - L'émulateur Storage n'applique pas la limite de 2 documents : seul l'analyseur statique la garantit.
- Le dossier `docs/claude/proposed-rules/` est conservé à titre d'historique : la proposition est désormais APPLIQUÉE (sans la partie Marketplace, volontairement exclue).

## D. Décisions explicitement prises (ne pas rouvrir sans demande)
Pas d'API Gateway ; pas de versionnement d'API ; pas de réorganisation de `functions/` ou de `lib/` en dossiers par domaine ; pas de Grand Livre wallet ; pas de renommage de schéma ; pas d'abstraction multi-fournisseurs de paiement ; pas de skill `/az-history` (décision du 2026-10-27).
