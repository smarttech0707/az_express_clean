# Suppression des comptes — préparation locale du 24 octobre 2026

Statut : PARTIEL. Aucune opération de production effectuée ou autorisée.
Les comptes existants et leurs commandes de livraison ne sont pas des données de test à supprimer.

## Reprise du 28 octobre 2026 — vérification du cycle de vie complet

Émulateurs uniquement, comptes fictifs. `operations_control/account_deletion` n'a pas été créé en production.

Anomalies confirmées et corrigées (chaque test échoue sans la correction) :
- Le selfie d'acceptation du livreur (`acceptance_selfies/<commande>/<uid>.jpg`) n'était jamais effacé de Storage ; `accountPersonalAssets.js` balaie désormais le dossier par pages et supprime les fichiers `<uid>.jpg` (erreur de reprise si le balayage est incomplet).
- `ownerName`, `operatorNumbers` (numéros mobile money E-Kbine) et `agencyName` survivaient à l'anonymisation des profils partenaires ; ajoutés à la liste des champs personnels.
- Artisans et prestataires d'événements n'avaient aucune voie de demande de suppression (ni écran, ni formulaire web, ni règle). Ils entrent maintenant dans la file manuelle `account_deletion_requests` (rôles `artisan`, `event_provider`), avec un bouton dans leur tableau de bord.
- `adminDriverRechargeCF` refuse de créditer un livreur supprimé ou en cours de suppression.

Résultats : 56/56 sur Auth + Firestore + Storage émulés (48 existants + 8 nouveaux dans `rules-tests/account-deletion-lifecycle.test.js`, profils réalistes). Lancer avec `--test-concurrency=1`.

Évaluation des quatre blocages :
1. Pharmacies historiques : inchangé. Le compte sans Firebase Auth ne peut utiliser que la file manuelle ; la suppression automatique exige la nomination super-admin puis l'acceptation avec un compte personnel. Aucun outil ne détruit un établissement.
2. Producteurs : le garde d'admission est présent dans orders, dispatch, acceptation, transferts, Ekbine, marketplace, AZ IA et la recharge manuelle. Non gardés (à traiter avant activation) : `professionalSubscriptions.js`, `eventReservations.js`, le webhook FeexPay (désactivé au lancement), les planificateurs qui écrivent des soldes.
3. Conservation : dossiers `*_requests`, conversations, `delivery_photos/<livreur>/` (preuves) et `account_deletion_requests` (téléphone) ne sont pas purgés ; durées légales non validées.
4. Établissement partagé avec dette : inchangé (blocage conservateur).
Prestataire d'événements : l'administration ne peut que suspendre ; aucun outil ne supprime son profil, son compte Auth ni ses fichiers. Procédure manuelle à définir avant d'annoncer une suppression.

## Corrections de cette reprise

- `accountAdmission.js` relit le tombstone de l'appelant dans la transaction d'admission, avant toute mutation. Un contrôle callable antérieur ne suffit pas contre une suppression concurrente.
- `accountRelatedPersonalData.js` limite l'anonymisation aux champs dont le propriétaire correspond effectivement à `clientId` ou `driverId`. Un vendeur également client ne doit pas effacer les coordonnées du client de ses ventes. `partnerAccountDeletion.js` utilise ce helper.
- Le dialogue décrit la suppression conditionnelle des partenaires et ne promet plus une séparation physique des pièces comptables non réalisée.
- Six tests backend et un test Flutter supplémentaires couvrent ces corrections.

## Résultats réels

- Backend complet : 948 réussis, aucun échec (les 159 tests ciblés sont inclus).
- Auth/Firestore/Storage Emulator et Firestore avec pannes simulées : 48 réussis en exécution séquentielle, dont 12 avec les trois services réels émulés et 36 avec Auth/Storage simulés.
- Premier essai parallèle : 29 réussis, 19 échoués. Les deux suites utilisent `demo-account-deletion`, et `clearFirestore` dans la suite de règles efface les données de l'autre suite. Exécuter avec `--test-concurrency=1`, jamais ensemble en parallèle sur ce projet.
- 19/19 tests Flutter réussis ; analyse des trois fichiers Flutter concernés : aucune anomalie.
- Aucun ancien binaire ni téléphone physique testé pendant cette reprise.

## Blocages restant ouverts

1. Pharmacies historiques : `currentUid` ne constitue pas une preuve de propriété. La nomination super-admin et l'acceptation avec une session personnelle récente existent, mais le parcours de connexion personnelle depuis la session anonyme historique reste à finaliser/valider. Ne jamais convertir ni supprimer automatiquement cette session. Aucun compte existant n'a été migré.
2. Les contrôles Admin SDK ciblés ne prouvent pas la couverture de toutes les révisions servies et de tous les producteurs différés. La protection transactionnelle ajoutée concerne les consommateurs de `accountAdmission`, pas un pare-feu global Admin SDK.
3. Copies historiques : les conversations, dossiers d'inscription et pièces financières ne disposent pas encore d'un inventaire de conservation entièrement traité. Ne pas les purger ni annoncer un effacement universel. Les durées et bases de conservation nécessitent validation ; aucune durée légale n'est inventée.
4. Établissement partagé avec dette/solde : blocage conservateur maintenu. Le support peut demander un réexamen après régularisation, mais ne peut pas annuler la dette, transférer implicitement une responsabilité ou forcer la suppression. La procédure opérationnelle de résolution reste à désigner.

## Mise à jour du 28 octobre 2026 (soir) — parcours par type de compte et plan d'activation

Émulateurs et tests unitaires uniquement ; rien déployé ; `operations_control/account_deletion` **non créé**.

### Parcours de suppression réellement disponibles
| Compte | Demande côté app | Traitement | Statut |
|---|---|---|---|
| Client, livreur | Dialogue de suppression (profil) | Automatique (`accountDeletion.js`) une fois le drapeau activé | Testé sur émulateurs ; **bloqué par le drapeau** |
| Vendeur/boutique, restaurant, boulangerie, agent E-Kbine, agent immobilier, patron de flotte | Feuille « compte partenaire » du tableau de bord | Automatique (`partnerAccountDeletion.js`) ; drapeau + `partnerInventoryVersion` | Testé émulateurs ; **bloqué par le drapeau** |
| Pharmacie avec propriétaire nommé (`pharmacy_owners`) | Feuille partenaire | Automatique après nomination super-admin et session personnelle récente | Testé émulateurs ; bloqué par le drapeau |
| **Pharmacie historique** (identifiants hachés, sans Auth) | Formulaire web `/suppression-compte` | **Manuel** : `completeManualAccountDeletionCF` (super-admin, preuve d'identité attestée) | Nouveau, testé émulateurs réels ; **fonctionne sans le drapeau** |
| **Artisan** | Bouton « Supprimer mon compte » (tableau de bord) | **Manuel** : même fonction | Nouveau, testé émulateurs réels |
| **Prestataire d'événements** | Boutons dans le portail (tableau de bord et écrans d'état) | **Manuel** : même fonction (supprime aussi le compte Auth) | Nouveau, testé émulateurs réels |
| Sous-administrateur | Aucun parcours self-service | Un super-admin le désactive (`isActive:false`) ; pas d'effacement de données | **Écart connu** : à traiter par procédure interne, non couvert par ce lot |

Blocages automatiques de la voie manuelle (réponse `blocked`, rien n'est supprimé) : solde ou dette non nuls, commande ou réservation non terminale, plus de 200 éléments d'historique, plusieurs rôles, propriétaire de pharmacie lié. Chaque finalisation exige méthode (rappel / en personne / document) + note de 10 à 300 caractères, et laisse une trace `audit_logs`.

### Gardes financières (nouveau)
`eventReservations.js` (garde d'admission + refus d'un prestataire en cours de suppression), `professionalSubscriptions.js` (refus sauf `suspend`/`deactivateVip`) et `adminDriverRechargeCF` sont désormais gardés. Restent hors garde : webhook FeexPay (inactif), planificateurs qui écrivent des soldes, circuits de retrait non relus.

### Utilisabilité après déploiement (vérifié par lecture du code, 28 octobre 2026)
- **Voie manuelle** (`completeManualAccountDeletionCF`) : n'exige **pas** le drapeau. Elle exige : fonction déployée, règle `account_deletion_requests` déployée (rôles artisan et event_provider), une demande existante, un super-admin avec l'écran « Finaliser » (nouvelle application admin).
- **Voie automatique** : les cinq fonctions du lot B doivent être déployées ET `operations_control/account_deletion` doit exister avec `enabled:true`, `inventoryVersion:1`, `partnerInventoryVersion:1`. Tant qu'il est absent (état actuel de la production), toute demande reste `pending`.
- **Blocages qui empêchent encore d'activer le drapeau** : (1) politique de conservation non validée (pièces financières, preuves de livraison, conversations, demandes d'inscription) ; (2) pharmacies historiques : pas de parcours de connexion personnelle finalisé, seule la voie manuelle existe ; (3) producteurs non gardés : webhook FeexPay (inactif), planificateurs qui écrivent des soldes, circuits de retrait non relus ; (4) établissement partagé avec dette : blocage conservateur sans procédure support désignée ; (5) sous-administrateurs : aucun parcours ; (6) aucun test sur appareil ; (7) fonctions de suppression, règles et applications non déployées.
- Aucun compte réel n'a été supprimé et aucune donnée de production modifiée.

### Plan sûr d'activation (à exécuter seulement après autorisation, étape par étape)
1. Déployer les fonctions de suppression et les règles (lots B et E du plan de publication). **Drapeau toujours absent.**
2. Créer un compte client fictif et un compte livreur fictif en production, faire une demande : elle doit rester `pending` (preuve que le garde bloque tant que le drapeau est absent).
3. Résoudre les blocages : (a) politique de conservation validée juridiquement (durées des pièces financières, preuves de livraison, conversations) ; (b) décision sur les pharmacies historiques (suppression manuelle seulement, ou migration vers compte personnel) ; (c) procédure support pour établissement partagé avec dette ; (d) garde des planificateurs/retraits si activés.
4. Créer `operations_control/account_deletion` avec `enabled:true, inventoryVersion:1, partnerInventoryVersion:1` — action de production, **autorisation distincte et explicite**.
5. Traiter d'abord un seul compte fictif de chaque rôle (client puis livreur, puis un partenaire), contrôler Auth, Firestore, Storage, tombstone, reçu, puis surveiller 24 h avant d'ouvrir plus largement.
6. Retour arrière : remettre `enabled:false` (le traitement s'arrête). Une suppression Auth effectuée n'est pas réversible ; ne jamais lever un tombstone pour « annuler ».
7. Ne pas rejouer automatiquement les anciennes demandes `pending`.

### Résultats de tests de cette mise à jour
Nouveaux tests sur Auth+Firestore+Storage émulés : `rules-tests/account-new-flows.test.js` (7/7) ; unitaires : `manualAccountDeletion` 11, `artisanPhotos` 7, `fleetDriverCreation` 7, gardes (réservations d'événements, abonnements) inclus dans la suite complète. Non testés : téléphone Android, iPhone.

## Séquence future — NON EXÉCUTÉE

1. Fermer les quatre points ci-dessus et établir un manifeste ciblé à partir des sources réellement servies. Conserver `operations_control/account_deletion.enabled` désactivé. Ne pas rejouer les anciennes demandes automatiquement.
2. Dans un environnement de validation séparé, avec uniquement des comptes fictifs dédiés, vérifier régions, Node.js 22, mémoire, délais, maximums d'instances, secrets référencés et identité de service. Ne pas remplacer ces paramètres par des valeurs déduites des sources locales.
3. Après autorisation distincte, installer les protections des producteurs et les règles Firestore/Storage validées. Les protections embarquées dans des modules partagés nécessitent les mises à jour de tous leurs consommateurs concernés ; leur liste de production complète reste à établir. Ne pas faire de déploiement global du workspace mêlant les autres développements.
4. Installer les cinq endpoints de suppression : `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `manageAccountDeletionCF`, `managePharmacyOwnerIdentityCF`, `retryAccountDeletions`. Les options locales sont dans `functions/index.js:67` à `74`; elles ne sont pas une preuve de la configuration de production. Garder le traitement désactivé jusqu'au contrôle des producteurs et des règles.
5. Produire des versions mobiles dédiées à la validation, pointant explicitement vers cet environnement. Android : `flutter build appbundle --release` seulement après vérification de la configuration Firebase et de la signature. iOS : sur Mac, `flutter build ipa --release` après vérification de la configuration Firebase, des capacités et de la signature. Aucun artefact produit ou publié dans cette reprise.
6. Tester la matrice ci-dessous. Distribution interne Android/TestFlight uniquement après autorisation. La publication publique et l'activation en production exigent deux validations explicites ; la nouvelle interface nécessite de nouvelles versions Android/iOS.
7. En cas d'erreur : suspendre le traitement automatisé, conserver reçus et tombstones, suivre les demandes `cleanup_pending` via le support. Ne jamais restaurer Auth ou lever un tombstone pour simuler un rollback. Une suppression Auth déjà effective n'est pas réversible par un retour de code.

Il n'existe pas encore de commande globale de déploiement sûre à exécuter : le manifeste complet des consommateurs et la correspondance des révisions de production sont des préconditions, pas des valeurs à inventer.

## Matrice appareils Android et iPhone

Utiliser seulement de nouveaux comptes fictifs dans l'environnement séparé. Ne pas utiliser les comptes réels de livraison conservés par l'utilisateur.

- Chaque rôle : demande avec authentification récente, état en cours, confirmation Auth absente, reconnexion refusée, absence de recréation du profil.
- Mission en cours : demande enregistrée, aucune nouvelle affectation, collecte/livraison et régularisation existantes toujours possibles.
- Solde positif ou dette : aucune mutation de montant par la suppression ; blocage expliqué, reprise seulement après régularisation autorisée.
- Pharmacie historique : preuve d'identité personnelle, nomination/consentement, aucun détournement via `currentUid`, établissement et autres responsables préservés.
- Multirôle : consentement couvrant tous les profils, coordonnées des autres participants intactes ; toute incohérence d'identité bloque.
- Perte réseau, arrêt/redémarrage, authentification expirée, échec Auth/Storage : aucune réussite prématurée, statut persistant et nouvelle tentative idempotente.
- Ancienne application : absence de contournement des tombstones, refus explicite des opérations protégées ; ne pas prétendre qu'elle dispose de la nouvelle interface.
- Support : droits super-admin, prise en charge et réexamen ; aucun bouton ne modifie les soldes ou ne force `completed`.

Critère de passage : tous les cas essentiels vérifiés, aucun accès d'un compte supprimé, aucune perte de données tierces ou financières, aucun producteur contournant les protections. Ce document n'autorise ni déploiement ni suppression réelle.
