# Plan de déploiement sécurisé : notation, S1–S8, journal vendeurs

**Rien n'est déployé.** Projet `az-express-b0469`, région `europe-west1`. Ce plan sépare ce que le dépôt local contient, pour que chaque lot soit déployé, vérifié et annulé séparément. Complète `docs/DRIVER_RATING_DEPLOYMENT_PLAN.md` (détails de la notation).

## 0. Faits de production (lecture seule, 2026-10-30)
- `admins` : **1 document, rôle `super`, 0 sous-admin**. Aucune règle ni fonction de permission ne change donc le comportement d'un compte existant.
- Règles en production : ruleset du 2026-10-28 (sauvegarde : `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt`). Fonctions : 95 déployées (`docs/FUNCTIONS_DEPLOYED_2026-10-30.txt`).

## 1. Ce que contient `firestore.rules` (un seul fichier, quatre ensembles)

Les règles se déploient en bloc : on ne peut pas publier « la notation seule » sans publier le reste du fichier. La séparation se fait donc **par retrait temporaire** d'un bloc dans une copie, ou par décision de tout publier ensemble.

| # | Ensemble | Blocs dans `firestore.rules` | Dépendance code | Risque de compatibilité |
|---|---|---|---|---|
| R1 | **Notation** | `ratingFieldOk`, `serverOwnedOrderFieldsUnchanged` (+3 champs), branche client `orders` | nouvelle app client (`rateOrder` n'écrit que `orders.rating`) + fonction F1 | anciennes versions de l'app : la note continue d'échouer (elle échouait déjà) ; aucune régression |
| R2 | **Consentement IA** | `match /ai_consents/{uid}` | déjà dans le dépôt, commité | aucun (nouvelle collection) |
| R3 | **S1 + S3** | `sellers` (création super seul, sous-admin limité à 6 champs), `pharmacy_guards` (suppression super seul) | aucune | un sous-admin ne pourrait plus créer / supprimer ; **0 sous-admin en production** → aucun effet |
| R4 | **S7 + S8** | `admins` : champs OTP retirés, `adminPermissionsKnown()` | liste identique côté Flutter (`auto_moto` ajoutée) | écriture client de la liste de permissions refusée si clé inconnue. La page « Gestion des admins » n'envoie que des clés de sa liste (toutes officielles). Écriture de `otp*` par un admin : plus permise, plus utilisée |

## 2. Fonctions

| # | Fonction | Contenu | Dépend de | Nouveau / modifié | Quota CPU |
|---|---|---|---|---|---|
| F1 | `applyDriverRatingOnOrderUpdate` | moyenne du livreur (idempotente, transactionnelle) | R1 pour être utile | **nouveau** | +0,5 |
| F2 | `checkWithdrawalStatus` | S2 : propriétaire ou super-admin | `adminGuards.js` (+ `ADMIN_MFA_MODE`) | modifié | 0 |
| F3 | `manageProfessionalSubscription` | S4 + décision abonnements : activations (standard, VIP, essai) et renouvellement d'un compte tiers = super-admin seul ; suspension / retrait VIP = permission de catégorie | `adminGuards.js` | modifié | 0 |
| F4 | `createSubAdmin` | S8 : permissions validées | `adminPermissions.js` | modifié | 0 |
| F5 | `notifyAdminsOnNewDriver`, `notifyAdminsOnNewServiceProvider`, `notifyAdminsOnEventProviderApplication`, et les fonctions qui appellent `logSecurityEvent` | S5 : routage par permission | `adminPermissions.js` | modifiés | 0 |
| F6 | `manageSellerAccountCF` | journal d'audit vendeurs | R3 non requis ; page non rattachée au menu | **nouveau** | +0,5 |
| — | Toutes les fonctions qui utilisent `requireAdminPermission` / `requireSuperAdmin` | `enforceAdminSecondFactor` en mode `log` (défaut) : trace uniquement | — | **redéployées avec le même module** | 0 |

Attention : `functions/index.js` et `adminGuards.js` sont partagés. Un déploiement ciblé (`--only functions:nom`) publie le **fichier entier** de la source, mais seules les fonctions listées sont remplacées. Les 26 fonctions du dépôt non déployées (QR, suppression de compte, preuves de livraison, SMS…) **ne sont pas** publiées par un `--only` ciblé. Ne jamais lancer `firebase deploy --only functions` sans nom.

Quota Cloud Run (règle du dépôt) : F1 + F6 = +1,0 CPU régional. Le quota était à ~119,5 après la réduction du Prompt 122 : vérifier avant (`firebase functions:list`), et en cas d'erreur « total allowable CPU per project per region », ne pas insister : réduire une fonction secondaire d'abord.

## 3. Ordre recommandé (chaque lot = vérification + retour arrière possible)

| Lot | Contenu | Pourquoi dans cet ordre |
|---|---|---|
| **A** | F2, F3, F4, F5 (sécurité des fonctions, sans changement de règle) | Sans effet visible avec 0 sous-admin ; bloque S2/S4 avant tout futur sous-admin |
| **B** | R1 + R2 + R3 + R4 (règles, en bloc) puis F1 | La fonction de notation n'a d'intérêt qu'avec les règles ; règles d'abord pour que les notes de la nouvelle app passent |
| **C** | F6 `manageSellerAccountCF` | Nouvelle fonction isolée, non appelée tant que la page n'est pas rattachée |
| **D** | Nouvelle version de l'application (notation, interface) | Les anciennes versions n'ont pas la notation fonctionnelle |
| **E** | `ADMIN_MFA_MODE=enforce` | Seulement après observation des journaux `admin_without_second_factor` |

Si vous préférez ne pas publier R3/R4 maintenant : retirer ces blocs de la copie à déployer (`git diff firestore.rules` les isole) ; c'est une décision à prendre, pas à improviser le jour du déploiement.

## 4. Commandes exactes (à exécuter UNIQUEMENT sur autorisation)

Avant tout lot :
```
cd D:\az_express_clean
git status --short            # le dépôt doit être celui qui a été testé
cd functions && npm test      # 0 échec attendu
cd .. && npm run test:rules   # (émulateur sur port libre ; Java requis)
firebase deploy --only firestore:rules --dry-run --project az-express-b0469
firebase functions:list --project az-express-b0469 > before_functions.txt
```
Lot A :
```
firebase deploy --only functions:checkWithdrawalStatus,functions:manageProfessionalSubscription,functions:createSubAdmin,functions:notifyAdminsOnNewDriver,functions:notifyAdminsOnNewServiceProvider,functions:notifyAdminsOnEventProviderApplication --project az-express-b0469
```
(vérifier d'abord dans `functions:list` les noms exacts des déclencheurs de F5, y compris ceux qui appellent `logSecurityEvent`.)
Lot B :
```
firebase deploy --only firestore:rules --project az-express-b0469
firebase deploy --only functions:applyDriverRatingOnOrderUpdate --project az-express-b0469
```
Lot C :
```
firebase deploy --only functions:manageSellerAccountCF --project az-express-b0469
```
Contrôles après chaque lot : `firebase functions:log --only <nom> --project az-express-b0469` ; connexion super-admin et chargement du tableau de bord ; un parcours client (création de commande) et un parcours livreur (acceptation) pour vérifier l'absence de régression.

## 5. Retour arrière

| Lot | Retour arrière |
|---|---|
| Règles (B) | republier `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt` (copier dans `firestore.rules` d'une copie propre, puis `firebase deploy --only firestore:rules`). Annule R1 à R4 ensemble. Ou console Firebase → Firestore → Règles → Historique |
| Fonctions modifiées (A) | redéployer la version précédente du fichier depuis Git (`git stash` n'est pas nécessaire : `git show HEAD:functions/<fichier>` pour récupérer l'original, redéployer le lot), ou console Cloud Run → révision précédente |
| Fonctions nouvelles (B/F1, C/F6) | `firebase functions:delete <nom> --region europe-west1 --project az-express-b0469` (suppression : autorisation explicite à ce moment-là). Les notes restent sur les commandes ; les journaux d'audit restent |
| `ADMIN_MFA_MODE=enforce` | retirer la variable (retour au mode `log`) et redéployer les fonctions admin |

Aucun de ces lots ne touche aux wallets, paiements, commissions, tarifs, dispatch ni statuts de commandes.

## 6. Risques de régression à surveiller

1. **Règles `admins`** : si une page écrit des permissions avec une clé hors liste, l'écriture est refusée (silencieuse côté Flutter). Les clés de la page « Gestion des admins » sont toutes officielles (test de parité).
2. **`auto_moto`** ajoutée à la liste Flutter : un compte qui l'aurait reçue n'est plus rejeté à la connexion. Personne ne l'a.
3. **S2** : un sous-admin ne peut plus vérifier un retrait d'autrui. Aucun écran Flutter n'appelle `checkWithdrawalStatus`.
4. **S4 + abonnements** : un sous-admin ne peut plus activer d'abonnement / VIP / essai ni renouveler le compte d'un tiers (super-admin seul). Seul le super-admin (1 compte en production) garde ces actions ; un administrateur propriétaire de son propre compte renouvelle comme propriétaire.
5. **S5** : un super-admin sans `role: 'super'` correct dans son document ne recevrait plus les notifications (production : OK, 1 admin `super`).
6. **Mode `log` MFA** : une ligne de journal par admin et par instance ; aucun blocage.
7. **AdminSellersPage** : non rattachée ; ses écritures passent par F6 (à déployer avant tout rattachement).
8. **Anciennes versions de l'application** : non concernées par R3/R4/F2–F6 ; la notation n'y fonctionne toujours pas.

## 7. Précision sur S5 (alertes de sécurité)
`logSecurityEvent` est défini dans `index.js` et injecté dans d'autres modules (`feexpayPayments.js`, `feexpayPayoutScheduler.js`, `adminPartnerAccounts.js`). La correction ne s'applique qu'aux fonctions **redéployées** : tant qu'un webhook FeeXPay ou un planificateur n'est pas redéployé, il garde l'ancien envoi à tous les admins actifs. Avec 0 sous-admin en production, l'effet réel est nul aujourd'hui ; avant la création du premier sous-admin, redéployer ces fonctions (liste à établir avec `firebase functions:list` + `grep logSecurityEvent`).

## 8. Second facteur du super-administrateur avant tout passage en `enforce` (décision : rester en `log`)
`ADMIN_MFA_MODE` reste à `log` (valeur par défaut, aucune variable à définir). Procédure de vérification avant d'envisager `enforce`, sans risque de blocage :
1. Console Firebase → Authentication → utilisateur super-admin → vérifier qu'un second facteur (TOTP ou SMS) est enrôlé.
2. Après le lot A, se connecter en super-admin et exécuter une opération admin ; chercher dans les journaux des fonctions la ligne `admin_without_second_factor` pour cet uid. **Absence de la ligne = le jeton porte bien le second facteur.** Présence = ne pas passer en `enforce`.
3. Répéter sur deux connexions distinctes (appareil mobile et web) sur plusieurs jours.
4. Garder un compte de secours documenté (procédure de récupération) avant `enforce`. Le retour arrière est immédiat : supprimer la variable puis redéployer les fonctions admin.
