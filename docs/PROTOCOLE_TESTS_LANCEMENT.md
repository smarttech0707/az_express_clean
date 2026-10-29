# Protocole de tests de lancement — AZ Express 1.0.10 (Android puis iPhone)

Préparé le 28 octobre 2026. Remplace la partie « scénarios » de `docs/ANDROID_TEST_PLAN.md` pour le lancement (espèces uniquement, remplacement de livreur désactivé). Aucun test financier n'est lancé par ce document.

## 1. Principe : deux niveaux, dans cet ordre
| Niveau | Backend | Argent | Quand |
|---|---|---|---|
| **A. Émulateurs** (`demo-az-express`) | Ordinateur, réseau local, aucun service externe | fictif, rejouable | **maintenant** |
| **B. Production** (`az-express-b0469`) | Vrais services | comptes de test dédiés, montants minimes | après accord explicite du propriétaire, uniquement pour ce que A ne peut pas prouver |

**Ce que A ne peut pas prouver (à refaire en B, comptes de test, sans argent réel) :** lecture des messages vocaux sous la limite de 2 documents des règles Storage ; notifications push ; carte Google Maps et suivi visuel ; fonctions planifiées (expiration automatique des commandes, remboursement à 48 h) ; les 95 fonctions réellement déployées (l'émulateur exécute les 120 fonctions du code local).

## 2. Garde-fous financiers (niveau A)
- L'application de test est un paquet distinct `com.azexpress.app.test`, configuré avec un projet factice `demo-…` : elle **refuse de démarrer** sur un vrai projet et ne contacte aucun service externe (FeexPay, SMS, IA, FCM bloqués).
- Relevé avant/après **à chaque opération d'argent** :
  `node test-env/snapshot-balances.js avant` → faire l'opération sur le téléphone → `node test-env/snapshot-balances.js apres`
  Le second appel affiche uniquement les différences : soldes (client, livreurs, vendeur), stock, nouvelles écritures `wallet_transactions`, commandes (statut, commission, selfie), `audit_logs`. Outil en lecture seule, limité à `127.0.0.1:8080`.
- Valeurs de départ (graine) : client 20 000 ; livreur A 5 000 ; livreur B 5 000 ; vendeur 0 ; stock « Riz 5 kg (test) » 10 ; `config/billing` = `accepted_only` / `block` (identique à la production).
- Critères d'arrêt : un solde différent de l'attendu ; une commission prélevée deux fois ; un crédit avant livraison ; un total affiché ≠ montant débité ; un stock restitué sans action admin.

## 3. Mise en route (PowerShell, depuis `D:\az_express_clean`)
Les émulateurs tournent déjà mais avec des **copies périmées** (règles du 27 octobre, avant la correction Storage) : les redémarrer.
```powershell
powershell -ExecutionPolicy Bypass -File test-env\emulators-stop.ps1
node test-env\stage-functions.js
node test-env\stage-storage-rules.js
node test-env\verify-emulator-isolation.js --strict-env
powershell -ExecutionPolicy Bypass -File test-env\emulators-start.ps1 -Persist
powershell -ExecutionPolicy Bypass -File test-env\emulators-seed.ps1        # demande un mot de passe de test (12 car. min.)
# Une fois (administrateur), pare-feu local : test-env\emulators-firewall.ps1 -Action Add
powershell -ExecutionPolicy Bypass -File test-env\build-emulator-apk.ps1 -EmulatorHost 10.131.214.87
powershell -ExecutionPolicy Bypass -File test-env\install-test-apk.ps1
```
IP du PC relevée : `10.131.214.87` (à revérifier, elle change avec le Wi-Fi). Un téléphone est détecté par adb : Infinix X6728B (`14733405CN007334`). L'APK de test existant (`build/app/outputs/flutter-apk/app-debug.apk`, 04:16) est **périmé** : le reconstruire.

## 4. Comptes de test (graine)
| Rôle | Connexion | Données |
|---|---|---|
| Client | téléphone `+2250100000001` + mot de passe de test | wallet 20 000 |
| Livreur A | identifiant `test-livreur-a` | approuvé, wallet 5 000 |
| Livreur B | identifiant `test-livreur-b` | approuvé, wallet 5 000 |
| Admin | `admin.test@az-test.invalid` (super-admin) | — |
| Vendeur | `vendeur.test@az-test.invalid` | wallet 0 ; produit Boutique `Riz 5 kg (test)` 5 000 FCFA, stock 10 ; produit Marketplace `Téléviseur (test)` |
Rôles sur les appareils : téléphone 1 = client puis admin (sessions successives) ; téléphone 2 = livreur A (idéalement un second pour B). Localisation « toujours », notifications autorisées (non testables en A), économie de batterie désactivée.

## 5. Les 12 parcours
Notation : **P** = prix de livraison affiché ; **c** = commission livreur (100 si P < 1 000, sinon 200 d'après le barème actuel). Pour chaque parcours : snapshot `avant` / `apres`.

| # | Parcours | Compte | Actions sur le téléphone | Résultat attendu | À vérifier dans Firebase (Firestore) |
|---|---|---|---|---|---|
| 1 | Connexion et inscription client | nouveau client fictif puis `+2250100000001` | Inscription (nom, téléphone, mot de passe), déconnexion, reconnexion | Accueil client ; wallet 0 pour le nouveau compte | `clients/<uid>` créé avec les champs d'inscription, `wallet` 0, pas de `isDeleted` |
| 2 | Connexion livreur | `test-livreur-a` | Connexion, passer « en ligne » | Tableau de bord ; selfie demandé à l'acceptation, pas à la connexion | `livreurs/<A>` : `isOnline=true`, `wallet=5000` |
| 3 | Création d'une commande de livraison | client | Livraison standard, **espèces**, ~2–3 km | Prix P affiché = prix débité (aucun débit en espèces) ; commande `pending` puis `assigned`/`broadcast` | `orders/<id>` : `paymentMethod=cash`, `budget=P`, `status`, `notifiedDriverIds` ; `audit_logs` |
| 4 | Acceptation avec selfie obligatoire | livreur A | Ouvrir l'offre, tenter d'accepter **sans** selfie, puis avec selfie (caméra frontale) | Refus sans selfie (`SELFIE_REQUIRED`) ; acceptation avec selfie | `orders/<id>` : `status=accepted`, `driverId=A`, `driverAcceptanceSelfie` ; fichier dans `acceptance_selfies/<orderId>/` (Storage) |
| 5 | Commission unique | livreur A | Accepter, relancer l'application, rouvrir la course | A = 5 000 − c, **une seule fois** | `livreurs/<A>.wallet` ; une seule entrée `wallet_transactions` type `commission` ; `orders/<id>` : `commissionStatus=charged`, `commissionAmount=c`, `commissionPayerId=A` |
| 6 | Recharge manuelle du portefeuille livreur | admin | Écran de recharge livreur : montant ≥ 1 000 FCFA (première recharge), double appui sur « Valider » | Un seul crédit ; refus au-dessus du plafond (défaut 50 000) | `livreurs/<A>.wallet` +montant ; une entrée `wallet_transactions` ; `audit_logs` action de recharge |
| 7 | Attribution et suivi GPS | livreur A + client | A en ligne, GPS actif, écran verrouillé 10 min ; le client ouvre le suivi | La position du livreur est mise à jour ; (carte : seulement avec une clé de test, voir README) | `livreurs/<A>` : `lat`, `lng`, horodatage récent ; `orders/<id>.driverId` |
| 8 | Confirmation de livraison | livreur A | Récupérer puis livrer | `picked_up` puis `delivered` ; livreur libéré | `orders/<id>.status=delivered` ; `livreurs/<A>.isOnDelivery=false` ; aucun second débit de commission |
| 9 | Achat Boutique en espèces | client | Boutique, `Riz 5 kg (test)` ×1, **cash** | Détail « 5 000 + 500 = 5 500 » ; aucun débit client ; stock 10 → 9 | `boutique_orders/<id>` (`totalAmount=5500`, `paymentMethod=cash`) ; commande liée `orders/<id>` avec `amountsVersion=1` ; `clients/<c>.wallet` inchangé |
| 10 | Achat Boutique avec wallet | client | Même produit, **wallet** ; ensuite double appui rapide sur « Payer » ; essai avec solde insuffisant | Client −5 500 ; vendeur +5 000 ; stock −1 ; **un seul** achat malgré le double appui ; solde insuffisant = rien débité | `clients/<c>.wallet`, `sellers/<s>.wallet`, `boutique_products/test-riz.stock`, `wallet_transactions` (client `purchase` 5 500, vendeur `sale` 5 000) |
| 11 | Remboursement (annulation ou expiration) | client / admin | (a) annuler avant récupération ; (b) annuler après récupération ; (c) remboursement 48 h via l'écran Boutique | (a) client rendu 5 500, vendeur repris 5 000, commission rendue ; (b) produits rendus, 500 retenus en attente admin ; (c) remboursé une fois, refusé si livraison en cours | `orders`/`boutique_orders` `status=refunded|cancelled`, `commissionStatus=refunded`, `deliveryFeeHold` ; rejeu = aucun mouvement. L'**expiration automatique** (`autoExpireOrders`) est planifiée : non testable en A |
| 12 | Lecture des messages vocaux | client + livreur | Envoyer un vocal dans le chat de la commande, le lire de l'autre côté, puis depuis l'admin | Lecture OK pour le client, le livreur et le super-admin ; refus pour un tiers | Fichiers `voice_messages/<orderId>/` ou `chat_audio/<orderId>/` (Storage). **À refaire en niveau B** : la limite de 2 documents des règles n'existe pas dans l'émulateur |

Cas de non-régression à ajouter en A : livreur avec solde < c (`CREDIT_INSUFFISANT`, aucune commission) ; commande Marketplace/Boutique historique `test-marketplace-historique` (acceptation refusée `LEGACY_PARTNER_ORDER`) ; ancienne application Boutique sans total accepté (`APP_UPDATE_REQUIRED`, rien débité).

## 6. Compatibilité des versions Android
- **Pour tester les dernières modifications : reconstruire.** L'AAB signé (`build/app/outputs/bundle/release/app-release.aab`, 28 oct. 07:04) est **antérieur** aux changements de `lib/screens/driver/driver_dashboard.dart` et `lib/constants/app_constants.dart` (drapeau `deliveryTransferEnabled=false` qui masque le remplacement de livreur). Installé tel quel, il afficherait un bouton « Remplacements » appelant des fonctions non déployées (`deliveryTransferCF`).
- Niveau A : l'APK de test (`com.azexpress.app.test`) se construit à partir du code courant avec `test-env\build-emulator-apk.ps1`.
- Niveau B et publication : `flutter build appbundle --release` (signature `key.properties`, `google-services.json` de production) après accord ; version actuelle `1.0.10+11` ; comparer le `versionCode` 11 à celui de la Play Console.

## 7. Prérequis iPhone
Mac avec Xcode (Codemagic utilise Xcode 26.0), CocoaPods 1.17.x, Flutter 3.44.5 ; compte Apple Developer de l'équipe `F6XWK2W7XG` ; `ios/Runner/GoogleService-Info.plist` et `lib/firebase_options.dart` de production à placer (non versionnés) ; clé APNs (.p8) chargée dans Firebase ; numéro de build iOS **à lire dans App Store Connect** puis `IOS_BUILD_NUMBER` ; `PrivacyInfo.xcprivacy` présent. Le mode émulateurs ne vise que l'Android : sur iPhone, seuls des tests en production (niveau B) sont possibles. Détail : `docs/IOS_MAC_BUILD_GUIDE.md`. Aucune compilation iOS n'a été faite depuis les changements.
