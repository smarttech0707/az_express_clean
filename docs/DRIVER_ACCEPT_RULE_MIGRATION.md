# Fermeture de l'acceptation directe (assigned → accepted) — plan de migration

Statut : **préparé, non appliqué**. `firestore.rules` n'est pas modifié pour cette
fermeture et rien n'est déployé.

## La faille

`firestore.rules`, collection `orders`, branche livreur : un livreur peut écrire
lui-même `status: 'accepted'` sur une course `assigned` qui lui est attribuée.
La commission AZ n'était prélevée que par la transaction Flutter
(`FirestoreService.acceptOrder`, ancienne version) : un client modifié peut donc
accepter sans payer. La preuve est dans
`rules-tests/driver-accept-closed.rules.test.js` (test « ÉTAT ACTUEL »).

## Ce qui est prêt

- `acceptOrderCF` (`functions/driverAcceptance.js`) : calcul de la commission,
  contrôle du portefeuille et débit côté serveur, idempotent, avec les mêmes
  gardes que l'ancienne règle (suppression de compte consentie).
- `FirestoreService.acceptOrder` appelle `acceptOrderCF` (version ≥ celle qui
  contient ce changement).
- Les champs de commission et de transfert sont déjà verrouillés pour le livreur
  dans les règles (`commissionAmount`, `commissionPayerId`, `commissionTxId`,
  `commissionStatus`, `acceptedAt`, `driverHistory`, `activeTransferId`,
  `transferCount`, `excludedDriverIds`, `requeuedAt`).
- La règle cible est validée en test : `closedRules()` remplace la branche
  `assigned → accepted` par `false`, sans autre changement.

## Dépendance des anciennes versions

Toute version de l'application livreur antérieure à celle qui appelle
`acceptOrderCF` accepte par une écriture Firestore directe. Retirer la branche
des règles de production **avant** que ces versions aient disparu les empêche
d'accepter toute course (erreur `permission-denied`).

Il n'existe pas de mécanisme de version minimale dans le dépôt (aucune
configuration `minAppVersion` lue par l'application livreur).

## Migration sûre (dans cet ordre)

1. Déployer les fonctions (`acceptOrderCF`, `releaseOrderBeforePickupCF`) — les
   anciennes applications continuent de fonctionner via la règle actuelle.
2. Publier la version de l'application livreur qui appelle `acceptOrderCF`
   (Android et iOS) et attendre sa diffusion.
3. Mesurer l'usage des anciennes versions (journal d'audit `accept_order`
   présent pour les nouvelles ; absence de `commissionStatus` sur les commandes
   acceptées = ancienne version).
4. Décision métier : imposer une mise à jour (blocage des versions anciennes) ou
   fixer une date de fermeture.
5. Retirer la branche `assigned → accepted` de `firestore.rules`, adapter les
   tests qui s'appuient sur l'acceptation directe
   (`rules-tests/driver-lifecycle.test.js`, `account-deletion-real.test.js`),
   faire passer `driver-accept-closed.rules.test.js` sans transformation, puis
   déployer les règles (`--dry-run` d'abord).
6. Surveiller les erreurs `permission-denied` sur `orders` pendant les premières
   heures ; retour arrière possible en redéployant la règle précédente.

## Cas à traiter à la fermeture

- Acceptation d'une diffusion (`broadcast`) : l'ancien code client écrit
  `driverId` sur une commande sans livreur ; la règle actuelle l'interdit déjà
  (`unchanged('driverId')`), `acceptOrderCF` gère les deux cas.
- Livraison QR (`deliveryProofMode == 'qr_v1'`) : déjà réservée aux fonctions.
- Commandes acceptées avant le suivi serveur de la commission (sans
  `commissionStatus`) : le remboursement garde la règle historique.

## Mise à jour — préparation de la fermeture (Phase 4, rien n'est appliqué)

### Comportement des anciennes applications après fermeture
Une ancienne version écrit `status:'accepted'` directement : après fermeture, Firestore répond
`permission-denied` et la course ne peut plus être acceptée (le dispatch peut la reproposer, sans effet).

### Limite du mécanisme de version minimale
`config/app_versions` n'est lu QUE par les versions qui contiennent `MinVersionService`. Une ancienne
version ne le lit pas : elle ne peut pas être bloquée par ce document. Il ne protège donc que la
transition suivante. Pour les versions antérieures, il faut une mise à jour forcée côté stores / un
contact direct des livreurs, et une mesure d'usage avant de fermer.

### Mesure (lecture seule, à lancer explicitement)
`node functions/scripts/legacyAcceptanceReport.js --project <id> --days 14`
`acceptedByLegacyApp` = courses acceptées sans `commissionStatus` (impossible pour `acceptOrderCF`).
Condition : 0 sur la période, `truncated:false`, après diffusion de la nouvelle version.

### Règle cible et tests
Branche `assigned → accepted` remplacée par `false` ; validée par
`rules-tests/driver-accept-closed.rules.test.js` (acceptation directe, diffusion, pending, usurpation,
champs de commission forgés, transitions légitimes inchangées). `npm run test:rules` : 362/362.

### Séquence
1. Déployer les fonctions, publier l'application livreur (appel de `acceptOrderCF`, contrôle de version).
2. Mesurer jusqu'à 0 ; communiquer la date de fermeture aux livreurs.
3. Activer `enforce` pour la nouvelle branche, puis retirer la branche des règles
   (`--dry-run` d'abord), surveiller les `permission-denied` sur `orders`, retour arrière = règle précédente.

## Préparation finale (aucune application, aucune version imposée)

### Règle cible exacte
Le diff complet est dans `docs/DRIVER_ACCEPT_CLOSED_RULES.diff` (une seule branche remplacée par `false` ; 4 lignes
retirées). Il est régénérable et vérifié par `rules-tests/driver-accept-closed.rules.test.js`.
Ne pas l'appliquer à `firestore.rules` avant les critères ci-dessous.

### Pourquoi la fermeture est aussi une mesure financière
Une ancienne application livreur accepte par écriture directe : sa commission est prélevée par l'ancien code Flutter,
sans trace (`commissionStatus` absent). Pour une commande Marketplace/Boutique historique, cette commission n'est donc ni
bloquée par `acceptOrderCF` (politique `legacyPartnerAcceptance`) ni rendue automatiquement à la livraison : elle est
seulement signalée (`legacyBillingReview`) pour résolution administrative. La fermeture supprime ce chemin.
Tant qu'elle n'est pas faite, ce résiduel est borné : commandes historiques + ancienne application livreur + acceptation directe.
La création de nouvelles commandes historiques est déjà bloquée par défaut (`APP_UPDATE_REQUIRED`).

### Critères avant fermeture (tous requis)
1. Nouvelle application livreur publiée et diffusée (Android + iOS), `acceptOrderCF` déployée.
2. `legacyAcceptanceReport.js` : `acceptedByLegacyApp = 0`, `truncated:false`, sur 14 jours après la diffusion.
3. Date de fermeture communiquée aux livreurs ; décision écrite d'imposer ou non une version minimale
   (`config/app_versions`, lu seulement par les versions contenant `MinVersionService`) — **aucune version n'est imposée par ce chantier**.
4. `npm run test:rules` vert, adapter `driver-lifecycle.test.js` et `account-deletion-real.test.js` (acceptation directe).
5. `firebase deploy --only firestore:rules --dry-run`, puis déploiement par vous, surveillance des `permission-denied`
   sur `orders` pendant 24 h ; retour arrière = redéployer la règle précédente.
