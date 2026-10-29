# QR/PIN livraison — phase 2, désactivée par défaut

## Fichiers de cette intervention

Nouveaux : `functions/deliveryProofGuests.js`,
`lib/delivery_proofs/delivery_proof_service.dart`,
`lib/delivery_proofs/proof_presentation.dart`,
`lib/delivery_proofs/proof_scanner_page.dart`,
`test/delivery_proofs/delivery_proofs_test.dart` et ce document.

Étendus : `functions/deliveryProofs.js`, `functions/index.js`,
`functions/test/deliveryProofs.test.js`, `rules-tests/firestore.rules.test.js`.
Dans `functions/orderActions.js`, seul le diagnostic d'une livraison QR déjà
confirmée est ajouté à la phase 1 ; le règlement financier n'est pas changé.

Intégrations : `lib/screens/restaurant/restaurant_owner_dashboard.dart`,
`lib/screens/pharmacie/pharmacie_dashboard.dart`,
`lib/screens/boulangerie/boulangerie_dashboard.dart`,
`lib/screens/seller/seller_dashboard.dart`,
`lib/screens/driver/driver_dashboard.dart`,
`lib/screens/customer_tracking_screen.dart`,
`lib/screens/client/order_tracking_map.dart`, `lib/web/web_router.dart`.

Dépendances : `pubspec.yaml`, `pubspec.lock` et le registre généré
`macos/Flutter/GeneratedPluginRegistrant.swift`.
Les modifications préexistantes de `firestore.rules`, `firebase.json`,
`CLAUDE.md`, de la distribution Hosting et des autres fichiers sont conservées.

Cette intervention ne déploie rien. Les changements locaux de phase 1 sont
conservés. Aucun certificat, version applicative, paiement ou suivi GPS modifié.

## Activation de test uniquement, après validation

Deux verrous indépendants : `DELIVERY_PROOFS_UI` (dart-define, faux par défaut)
et `DELIVERY_PROOFS_ENABLED` (environnement Functions, doit valoir `true` pour
émettre une preuve ou créer/utiliser un accès destinataire). Aucun environnement
réel n'a été activé. Les confirmations existantes restent disponibles pour
terminer une commande déjà en `qr_v1`.

`DELIVERY_PROOF_RECIPIENT_ORIGIN` doit désigner l'origine HTTPS du site de test.
Aucune origine de production n'est choisie par défaut. Ne pas activer le client
sur des commandes de production pour tester. La création de la première preuve
de récupération transforme explicitement la commande en `qr_v1`.

## Interfaces

- Cartes restaurant, pharmacie, boulangerie et vendeur : bouton de récupération
  après acceptation par un livreur. Si `sellerStatus` existe, il doit être `ready`.
  Pour les parcours sans statut de préparation, confirmation manuelle « commande
  prête » avant émission. L'autorisation réelle demeure côté serveur.
- Suivis client (`CustomerTrackingScreen`, `OrderTrackingMap`) : récupération
  pour l'expéditeur sans commerce, réception après récupération validée.
- Livreur : caméra sur action explicite, PIN manuel, contrôle local du format
  QR/commande/étape, puis validation serveur. Une lecture caméra ne modifie pas
  Firestore. La récupération demande confirmation ; la livraison conserve la
  feuille photo/GPS/cash existante avant appel serveur.
- Réception publique `/#/reception/:grantId` : saisie du code de récupération,
  authentification Firebase anonyme si nécessaire, affichage QR/PIN en mémoire.
  Aucun compte AZ Express n'est nécessaire, mais Firebase Auth anonyme doit
  être autorisé dans l'environnement de test.

## Contrats et protections

`prepareOrderProof({orderId,type})` renvoie `{success,orderId,type,token,pin,expiresAt}`.
`type` vaut `pickup` ou `delivery`. Les boutiques exigent un document
`sellers/{uid}` actif, de type boutique, non suspendu et correspondant au vendeur
de la commande. Restaurant/pharmacie conservent leurs liens d'identité phase 1.

`confirmOrderPickupWithProof({orderId,token|pin})` ne retourne aucun secret.
`confirmOrderDeliveryWithProof({orderId,proofToken|proofPin,markCashPaid,
deliveredLat,deliveredLng,deliveryPhotoUrl})` réutilise le règlement phase 1.
Les transactions existantes empêchent consommation et crédit en double.

Deux nouveaux callables :

1. `createRecipientProofAccess({orderId})` : client propriétaire uniquement,
   commande récupérée avec preuve utilisée. Retourne `grantId`, `recovery` et
   `expiresAt`. Le livreur assigné est refusé. Au plus trois accès par commande.
2. `redeemRecipientProofAccess({grantId,recovery})` : session Firebase requise,
   y compris anonyme. Le livreur assigné et les comptes du registre `livreurs`
   sont refusés. Vérifie affectation, statut, expiration, dernier accès actif et
   code ; cinq erreurs maximum, comptabilisées dans une transaction. Consomme
   l'accès une fois et émet la preuve de réception dans la même transaction,
   sous la limite de trois générations de preuves de phase 1.

Le lien WhatsApp contient seulement un identifiant d'accès, sans QR, PIN ni code
de récupération. Il ne suffit pas à obtenir la preuve. Le client communique le
code de récupération séparément, en personne ou par appel au destinataire.
Il ne doit pas le communiquer au livreur. Aucune identité téléphonique n'est
automatiquement vérifiée : possession de ce code = délégation du client.
Ce mécanisme ne protège pas d'un destinataire qui transmet volontairement tous
ses moyens d'accès à un tiers.

Les accès et preuves sont sous `delivery_proofs`, collection refusée par les
règles à tous les clients. Seuls des hachages sont persistés, jamais les secrets
en clair. Aucun secret dans notification, journal ou URL. Émission et accès
expirent après 15 minutes ; l'accès est à usage unique. Perte/fermeture/échec de
réponse après consommation : demander un nouvel accès au client, dans la limite
serveur. Pas de récupération non authentifiée, pas de SMS/WhatsApp automatique.
Les secrets restent visibles à l'écran pendant leur présentation : ne pas
partager de capture. Ils ne sont pas persistés par l'interface.

## Vérifications locales

- 23 tests `deliveryProofs.test.js` et 54 tests `orderActions.test.js` : 77 PASS.
- 10 tests Flutter QR/PIN : PASS avec drapeau absent, puis avec drapeau activé
  uniquement dans le processus de test.
- 20 tests Flutter suivi caméra/création et tarif des livraisons : PASS.
- 2 tests de règles `delivery_proofs` dans l'émulateur Firestore : PASS, incluant
  lectures et écritures des accès destinataires refusées.
- Analyse Flutter ciblée : aucun diagnostic.
- Dépendances résolues : mobile_scanner 7.4.2, qr_flutter 4.1.0, qr 3.0.2.
  Aucun autre package mis à niveau. Permissions caméra Android/iOS déjà présentes.
  Le registre macOS a été actualisé automatiquement par `flutter pub get`.

Commandes reproductibles :

```text
node --test functions/test/deliveryProofs.test.js functions/test/orderActions.test.js
flutter test --no-pub test/delivery_proofs/delivery_proofs_test.dart
flutter test --no-pub --dart-define=DELIVERY_PROOFS_UI=true test/delivery_proofs/delivery_proofs_test.dart
firebase emulators:exec --only firestore --project demo-az-express-qr "node --test --test-name-pattern=delivery_proofs rules-tests/firestore.rules.test.js"
```

## Avant essais réels / publication

Faire valider les contrats et la procédure de récupération séparée. Préparer un
projet de test et ses configurations Firebase, puis autoriser séparément tout
déploiement. Vérifier les index/règles et les identités partenaires réelles.
Sur Mac, `pod install` devra résoudre le plugin scanner ; aucun build iOS n'a été
exécuté sur Windows. Tester Android/iPhone physiques : permission refusée,
caméra, interruption/reprise, QR réel, PIN, mode hors ligne, expiration,
réaffectation, double validation, proche anonyme, récupération après fermeture,
photo/GPS/cash et anciennes commandes. Les mocks et tests widgets ne constituent
pas une certification du parcours complet ni des builds natifs.
