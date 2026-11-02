# Notation des livreurs — vérification finale et plan de déploiement

Statut au 2026-10-30 : **code prêt et testé, rien n'est déployé**. Projet `az-express-b0469`, région `europe-west1`.

## 1. Ce qui est déployé aujourd'hui et ce qui change

| Élément | Production aujourd'hui | Après déploiement |
|---|---|---|
| Règles Firestore | version du 2026-10-28 (ruleset `28112bcd-80a1-441a-8131-3b9873b12a72`) | note posée une seule fois, entier 1..5 ; champs de notation interdits au livreur |
| Cloud Function | `applyDriverRatingOnOrderUpdate` **absente** | calcule la moyenne du livreur |
| Application | l'ancien client tente d'écrire `livreurs/*` (refusé) | `rateOrder` n'écrit que `orders.rating` |

**Le déploiement des règles embarque aussi `match /ai_consents/{uid}`** (lecture propriétaire/admin, écriture interdite), déjà dans le dépôt mais pas encore en production. C'est la seule différence autre que la notation (voir `git diff --no-index docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt firestore.rules`).

**26 fonctions du code ne sont pas déployées** (QR partenaires, suppression de compte, preuves de livraison, SMS…). Le déploiement ciblé `--only functions:applyDriverRatingOnOrderUpdate` ne touche à aucune d'elles.

## 2. Vérification de sécurité (résultats)

| Exigence | Où c'est garanti | Preuve |
|---|---|---|
| Une seule note par commande | règle `ratingFieldOk` (champ absent → posé une fois) ; marqueur `driverRatingApplied` | `rules-tests/order-rating.rules.test.js` |
| Entier de 1 à 5 | règle (`is int`, 1..5) **et** fonction (`isValidRating`) | règles + `driverRatings.test.js` |
| Seul le client propriétaire | branche `isOwner(clientId)` + commande `delivered` | règles : autre client, livreur, anonyme refusés |
| Note non modifiable ni supprimable | `ratingFieldOk` : `rating` déjà présent → refus (y compris `deleteField`) | règles |
| Le livreur ne touche pas aux champs de notation | `rating`, `sellerRating`, `driverRatingApplied` ajoutés à `serverOwnedOrderFieldsUnchanged` | règles : 3 écritures refusées au livreur assigné |
| Idempotence | marqueur posé dans la même transaction que la moyenne | tests fonction + émulateur |
| Exécutions simultanées | transaction Firestore ; `maxInstances:1`, `concurrency:1`, `retry:true` | émulateur : 20 exécutions sur une commande = 1 note ; 10 commandes × 2 = compteur exact |
| Moyenne et compteur cohérents | écrits ensemble dans la même transaction | tests |
| **Anciennes commandes déjà notées** | la fonction n'agit que sur la transition « pas de note valide → note valide » (`before`/`after`) | `driverRatings.test.js` + émulateur : « notée avant le module : jamais recomptée » |
| Échec partiel / nouvelle tentative | transaction atomique : rien d'écrit si échec ; la tentative suivante compte une fois | test « échec avant validation » |
| Aucun impact argent/statut | la fonction n'écrit que `livreurs.avgRating/ratingCount` et `orders.driverRatingApplied` | test : wallet, statut, budget, commission inchangés |

**Défaut corrigé pendant cette vérification** : les commandes notées par l'ancien client n'ont pas de marqueur ; sans la garde `before`, la moindre mise à jour ultérieure (règlement, revue admin) les aurait recomptées.

**Limite connue** : la moyenne est arrondie à 1 décimale à chaque note (comme l'ancien calcul). Sur un très grand nombre de notes, l'arrondi cumulé dérive très légèrement. Corriger demanderait un champ `ratingSum` (additif) : non fait, à décider.

**Comportement des anciennes versions de l'application** : elles continueront d'échouer à noter (leur transaction écrit `livreurs/*`, refusé), avec un message d'erreur depuis ce correctif. Seule la nouvelle version fonctionne de bout en bout.

## 3. Plan de déploiement (rien n'est exécuté sans autorisation)

### Étape 1 — Relevé de la configuration actuelle (fait, lecture seule)
- Règles déployées sauvegardées : `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt` (ruleset `28112bcd-…`, mis à jour le 2026-10-28 17:31 UTC).
- Fonctions déployées : `docs/FUNCTIONS_DEPLOYED_2026-10-30.txt` (95 fonctions).

### Étape 2 — Vérification des règles (faite)
- `rules-tests` : 384 tests réussis sur émulateur temporaire (suite `test:rules` complète).
- À refaire juste avant le déploiement si le dépôt a changé : `git diff --stat firestore.rules` doit rester limité à la notation + `ai_consents`.

### Étape 3 — Dry-run (fait pour les règles)
```
firebase deploy --only firestore:rules --dry-run --project az-express-b0469
```
Résultat du 2026-10-30 : « rules file firestore.rules compiled successfully ». Il n'existe pas de dry-run pour les fonctions ; `node -e "require('./index.js')"` (chargement sans erreur) et les tests en tiennent lieu.

### Étape 4 — Déploiement ciblé des règles
```
firebase deploy --only firestore:rules --project az-express-b0469
```
Contrôle immédiat : console Firebase → Firestore → Règles → date de publication ; puis une lecture normale dans l'application (aucune régression d'accès).

### Étape 5 — Déploiement ciblé de la fonction
```
firebase deploy --only functions:applyDriverRatingOnOrderUpdate --project az-express-b0469
```
- Ajoute 0,5 CPU × 1 instance au quota Cloud Run régional. Si l'erreur « total allowable CPU per project per region » apparaît : ne pas insister, réduire d'abord une autre fonction (règle du dépôt).
- Ne déployer **jamais** `--only functions` sans nom (cela publierait les 26 fonctions non déployées).

### Étape 6 — Test contrôlé
Préférer d'abord l'environnement d'émulateurs (`test-env/`). En production, uniquement avec des comptes de test dédiés et votre accord explicite (aucune donnée de production réelle) :
1. Choisir un livreur de test ; noter `avgRating` et `ratingCount` (console Firestore).
2. Une commande `delivered` d'un client de test, sans `rating`.
3. Noter 4 étoiles depuis l'application du client de test.
4. Vérifier : `orders/{id}.rating = 4`, `driverRatingApplied = true`, `livreurs/{id}` : compteur +1, moyenne attendue.
5. Tenter une seconde note et une modification : refusées (message dans l'application).
6. Mettre à jour la commande autrement (ex. champ neutre par un admin) : le compteur ne bouge pas.

### Étape 7 — Journaux et moyenne
```
firebase functions:log --only applyDriverRatingOnOrderUpdate --project az-express-b0469
```
Chercher `driver_rating_applied` (contient `driverId`, valeurs `previous` et nouvelles). Aucune erreur attendue ; en cas d'`ABORTED`, la plateforme rejoue (idempotent).

### Étape 8 — Retour arrière
| Si… | Alors… |
|---|---|
| Les règles posent problème | Restaurer le ruleset précédent. Console : Firestore → Règles → Historique → republier la version du 2026-10-28. Ou en ligne de commande : republier le contenu de `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt` (copié dans un fichier de règles temporaire, sans écraser `firestore.rules`). Effet immédiat, sans perte de données. |
| La fonction se comporte mal | `firebase functions:delete applyDriverRatingOnOrderUpdate --region europe-west1 --project az-express-b0469` (suppression : demande d'autorisation explicite à ce moment-là). Les notes restent sur les commandes. |
| Une moyenne a été faussée | Les journaux `driver_rating_applied` donnent les valeurs `previous` : restaurer `avgRating`/`ratingCount` du livreur à la main (une écriture admin), puis retirer `driverRatingApplied` des commandes concernées **seulement si** l'on veut qu'elles soient recomptées. |

Aucune des deux opérations ne touche aux wallets, commissions, paiements ou statuts.

## 4. Tests exécutés (résumé)
- Fonction : 18 tests unitaires + 3 tests d'émulateur (concurrence réelle) réussis.
- Règles : 12 tests de notation + suite complète (384) réussis.

## 5. Mise à jour du 2026-10-30 (soir) — `firestore.rules` contient maintenant aussi S1 et S3

Les règles Firestore forment **un seul fichier** : déployer la notation déploie aussi, tels quels, les correctifs de permissions administratives faits après ce plan. Le diff attendu de `firestore.rules` contre la production est désormais :

1. notation (`ratingFieldOk`, champs serveur) ;
2. `match /ai_consents/{uid}` ;
3. **S1** `sellers` : création et mise à jour libre réservées au super-admin ; sous-admin `demandes_vendeurs` limité à `name, phone, type, isActive, lat, lng` ;
4. **S3** `pharmacy_guards` : suppression réservée au super-admin.

Conséquences à connaître avant l'étape 4 :
- Aucun effet sur les clients, livreurs, vendeurs propriétaires, paiements, commissions, wallets, commandes.
- Seul effet visible : un **sous-admin** `demandes_vendeurs` ne peut plus écrire que la fiche d'un vendeur (et plus créer / supprimer / toucher wallet, abonnement, VIP, suspension). Les `admins` de rôle `sub` actuellement en production sont à relever (lecture seule) avant le déploiement : `admins` où `role == 'sub'`.
- Si vous préférez déployer la notation **sans** S1/S3 : retirer ces deux blocs de la copie à déployer ; ne pas le faire sans décision (le fichier du dépôt est la source unique).
- Les correctifs S2 et S4 sont dans des **Cloud Functions** (`checkWithdrawalStatus`, `manageProfessionalSubscription`) : non déployés, déploiement ciblé distinct (`--only functions:checkWithdrawalStatus,functions:manageProfessionalSubscription`), à valider séparément.
- Étape 2 à refaire : `npm run test:rules` (inclut maintenant `sub-admin-s1-s3.rules.test.js`).
- Retour arrière des règles : inchangé (republier `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt`) ; il annule aussi S1/S3.
