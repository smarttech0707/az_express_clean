# Mission L4.9.1 — Audit complémentaire des chemins administratifs

Lecture seule. Aucun code, test, règle, configuration ou secret modifié ou affiché ; aucun accès Firebase ; aucun script pilote lancé. Légende : **[F]** fait vérifié dans le dépôt ; **[H]** hypothèse (plateforme ou production non vérifiable) ; **[R]** recommandation.

**Verdict** : aucun de ces trois fichiers ne permet de créer, promouvoir ou désactiver un administrateur, et aucun ne touche aux rôles ni aux permissions. Mais `passwordReset.js` **ne protège pas les comptes dont l'identifiant est aussi administrateur** (changement de mot de passe sans exclusion `admins`, sans audit, sans révocation de session), ce qui ajoute un chemin de récupération/prise de contrôle indirect à ceux de L4.9. `fcmTokenCleanup.js` ne modifie pas les protections N2 mais peut dégrader la **détection** (alertes aux admins). `guard.js` est solide contre la production mais couvre seulement une partie des scripts.

## 1. État initial Git

HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 162 non suivis (vérifié avant toute inspection).

## 2. `functions/passwordReset.js` (108 lignes, lu intégralement ; ne figure pas dans mes modifications)

**Faits [F].**
- **Branchement** : `index.js` `exports.resetAccountPassword = onCall({ maxInstances: 2 }, buildResetAccountPassword({...}))`. Pas de `enforceAppCheck`. L'ancienne implémentation est **commentée** dans `index.js` (bloc `resetAccountPasswordLegacy`) : code inactif, mais il illustrait un défaut de résolution d'UID, désormais corrigé par la recherche unique.
- **Qui peut demander** : tout utilisateur connecté dont le jeton porte `phone_number` (session Firebase Phone Auth). Pas de contrôle de rôle ni de MFA.
- **Contrôle d'identité** : le numéro fourni doit égaler le numéro vérifié du jeton (normalisation CI) ; le document cible est trouvé par **numéro unique** (`phone ==`, trois formes) dans une collection de la liste fermée : `clients`, `fleet_owners`, `sellers`, `restaurant_owners`, `boulangeries`, `pharmacies`, `service_providers` (selon `userType`). **`admins` n'est pas dans la liste** : un administrateur ne peut pas être ciblé *en tant qu'administrateur*.
- **Effet** : pour les types Firebase Auth (client, fleet, seller, restaurant, boulangerie) `auth.updateUser(<id du document>, { password })` — mot de passe ≥ 8 caractères, une majuscule, un chiffre. Pharmacie : hachage dans `pharmacie_credentials` ; artisan : PIN haché (`artisanCredentials.setPin`).
- **Protections** : refus si `isDeleted`, refus si le compte est en suppression (`assertTargetNotClosing` sur l'id du document et `currentUid`), plusieurs comptes pour un numéro ⇒ refus, limitation **5 appels/heure par uid appelant** (`reset_password`).
- **Absences** : **aucune lecture de `admins`** (l'identifiant du document est utilisé comme UID Auth sans vérifier que cet UID n'est pas un administrateur — contrairement à `adminPartnerAccounts.js`, qui refuse les cibles présentes dans `admins`) ; **aucune trace d'audit** (`logAudit`/`logSecurityEvent` absents du module et de son câblage) ; **aucun `revokeRefreshTokens`** après le changement ; aucune notification au titulaire ; limitation seulement par appelant (pas par numéro cible ni par IP) ; aucun test mentionnant `admin` dans `functions/test/passwordReset.test.js` (recherche textuelle).
- **Interactions** : `admins` — aucune lecture/écriture ; Auth — `updateUser` ; custom claims — aucun ; `ADMIN_MFA_MODE` — sans effet ici ; `createSubAdmin/deleteSubAdmin` — aucune.

**Hypothèses [H].**
- Si l'identifiant d'un super-admin figure aussi comme document d'une des collections listées (double rôle, possible puisque `admins` n'exclut pas un uid déjà client/vendeur, cf. L4.9 scénario 11) **et** que ce document porte un numéro de téléphone, quiconque contrôle ce numéro (SMS, échange de carte SIM) peut définir le mot de passe e-mail de ce compte. En mode `log` cela donne l'accès administrateur complet ; en mode `enforce` le second facteur déjà enrôlé subsiste normalement après un changement de mot de passe [H plateforme], donc la prise de contrôle serait bloquée.
- Le jeton d'un compte administrateur n'expose normalement pas `phone_number` s'il n'a que le second facteur SMS enrôlé (facteur ≠ fournisseur) [H] ; non vérifiable ici.
- Les sessions ouvertes de la victime restent valides jusqu'à expiration/rafraîchissement du jeton faute de révocation.

**Conclusion** : pas de réinitialisation *directe* d'administrateur possible via la liste de types ; chemin *indirect* pour les uid à double rôle ; absence totale de traçabilité.

## 3. `functions/fcmTokenCleanup.js` (100 lignes, lu intégralement)

**Faits [F].**
- Planificateur hebdomadaire (lundi 05:00, Abidjan), `maxInstances: 1`, `cpu: 0.5` ; erreurs consignées sans propagation.
- Lit `invalid_fcm_tokens` (≤ 400 entrées/exécution), puis pour chaque jeton cherche `fcmToken == jeton` (limite 5) dans 10 collections, dont **`admins`**, et exécute `update({ fcmToken: FieldValue.delete() })` par lot. **Seul le champ `fcmToken` est modifié** ; les entrées traitées sont supprimées.
- Acteur : Admin SDK (hors règles), sans contrôle de rôle, sans audit.
- Alimentation de `invalid_fcm_tokens` : `index.js` (échecs d'envoi FCM, écriture serveur) ; règle Firestore `invalid_fcm_tokens` : `allow read, write: if false`.
- `fcmToken` est modifiable par le propriétaire sur `admins` (règle W6 de L4.9).

**Évaluation** : ne touche ni `role`, `isActive`, `permissions`, ni Auth, ni claims ; ne peut pas altérer les protections N2 ni la révocation. **Effet indirect [F/H]** : les notifications administratives (alertes `logSecurityEvent` pour sévérité haute/critique, alertes de commandes bloquées) passent par `fcmToken` des admins ; un jeton effacé supprime l'alerte push pour cet admin jusqu'à la reconnexion/rafraîchissement. Un administrateur (ou un compte qui connaît un jeton d'un autre) pourrait provoquer l'effacement du jeton d'un autre admin en inscrivant ce jeton comme `fcmToken` sur son propre document puis en le rendant invalide [H, scénario théorique ; nécessite le jeton exact]. Aucune alerte n'est émise lorsque le jeton d'un administrateur est effacé.

## 4. `scripts/restaurant-v2-pilot/guard.js` (78 lignes, lu intégralement ; `lot.js` partiellement)

**Faits [F].**
- **Refus par défaut** : projet explicite obligatoire ; liste de refus `FORBIDDEN_PROJECT_IDS` = `az-express-b0469`, `az-express-clean` ; liste d'autorisation = **une seule cible préproduction** (identifiant + numéro de projet) ou projet `demo-*` avec `FIRESTORE_EMULATOR_HOST` obligatoire ; le numéro de projet est vérifié (lecture Resource Manager, en ligne, pour préproduction) ; variables d'environnement projet (`GCLOUD_PROJECT`, `GOOGLE_CLOUD_PROJECT`, `CLOUDSDK_CORE_PROJECT`, `FIREBASE_PROJECT`, `FIREBASE_CONFIG`) contradictoires ⇒ refus ; variables d'émulateur avec un projet réel ⇒ refus ; phrase de confirmation exacte (verbe + lot + projet + numéro) ; dossier de sortie des identifiants **hors du dépôt**.
- **Configuration absente/incorrecte** : refus (`PROJECT_REQUIRED`, `PROJECT_NOT_ALLOWED`, `PROJECT_NUMBER_MISMATCH`, `CONFIRMATION_REQUIRED`) ; erreurs typées.
- **Usage** : `guard` est importé par `prepare.js`, `cleanup.js`, `closeWatchdog.js`, `emergencyClose.js`, `intruder.js`, `runStep.js`, `storageInventory.js` ; `firstRun.js` et `financialReport.js` ne l'importent pas (plan/analyse, aucune connexion observée à la lecture).
- **Écriture admin** : `lot.js` génère la fixture `admins/<uid du lot>` (`role:'super'`, `isActive:true`, marque de lot) pour préproduction ; `cleanup.js` n'autorise que ce chemin dans sa liste blanche.

**Limites [F/H].**
- Les identifiants de production codés sont deux ; un **autre** identifiant de production inconnu serait refusé par la liste d'autorisation, pas par la liste de refus — la protection repose donc sur l'allow-list unique (solide).
- `GOOGLE_APPLICATION_CREDENTIALS` / identifiants par défaut ne sont pas inspectés : `connect()` utilise `applicationDefault()` avec un `projectId` explicite ; un compte de service de production avec accès au projet préproduction n'est pas détecté [H, configuration hors dépôt].
- Le contrôle de numéro de projet est en ligne (échec réseau ⇒ pas d'exécution, donc fail-closed). Les protections par chaîne d'arguments sont **contournables par un opérateur** qui édite le script (limite incompressible ; seule la revue de code et la CI les couvrent).
- Un super-admin de préproduction est créé avec mot de passe généré (stocké hors dépôt) : sur préproduction, l'état MFA de ce compte est inconnu [H].

**Risque d'exécution accidentelle en production** : faible grâce à la combinaison allow-list + confirmation exacte + vérification du numéro de projet ; non nul via identifiants par défaut mal configurés.

## 5. Cartographie des opérations sensibles découvertes

| Opération | Fichier | Effet sur admins/N2 | MFA | Audit |
|---|---|---|---|---|
| Changement de mot de passe d'un compte Auth (clients, fleet, sellers, restaurants, boulangeries) | `passwordReset.js` | **possible sur un uid à double rôle admin** | non | **aucun** |
| Effacement de `fcmToken` (10 collections dont `admins`) | `fcmTokenCleanup.js` | aucun sur droits ; dégrade les alertes | n/a | console seulement |
| Création/suppression de la fixture `admins/<lot>` (super) | scripts pilotes | création d'un super sur préproduction | non | manifeste hors dépôt |
| Déjà connus (L4.9) | `createSubAdmin`, `deleteSubAdmin`, règles `admins` W3–W6, `set_admin_claim.js`, console | — | partiel | partiel |

## 6. Scénarios de contournement

1. **Reset d'un super-admin à double rôle** : possible en théorie (§2), sans MFA ni trace ; conditionné à un document portant le téléphone et au contrôle de ce numéro. **Non confirmé par exécution.**
2. **Reset direct d'un compte uniquement admin** : impossible (aucune collection `admins` dans la liste ; `userType: 'admin'` ⇒ « Type invalide »).
3. **Combinaison L4.9 W3 + reset** : un super malveillant promeut un uid existant (client) en super puis, si ce client a un numéro vérifiable, peut utiliser la réinitialisation pour retrouver l'accès après désactivation ; la combinaison est réaliste en insider.
4. **Effacement de jeton d'alerte** : réduit la visibilité d'événements sécurité (§3) sans modifier les protections.
5. **Pilote en production** : bloqué par `guard.js` ; contournable seulement par modification du script ou des identifiants de projet de l'opérateur.
6. **Récupération d'accès** : seule voie documentée dans le dépôt = console/Admin SDK (limite incompressible) ; `sendPasswordResetEmail` côté client (`generic_forgot_password_page.dart`, `auth_service.dart`) peut être utilisé pour un compte e-mail/mot de passe administrateur : lien envoyé à l'e-mail du compte ; la sécurité dépend alors de la boîte mail et, en `enforce`, du second facteur [H].

## 7. Interactions avec L4.9

Aucune de ces trois pièces n'invalide L4.9 ; elles ajoutent : un chemin de **modification de mot de passe** non lié à `admins` (R12 ci-dessous), un lien entre **double rôle** et prise de contrôle (aggrave le scénario 11 de L4.9), l'absence de **révocation de session** après changement de mot de passe, et un risque de **dégradation de détection** (la détection hors-bande recommandée en L4.9 §7.6 s'appuie sur des alertes envoyées par `fcmToken`). Les scripts pilotes ne modifient pas le niveau de risque en production.

## 8. Risques classés

| Id | Risque | Gravité |
|---|---|---|
| R12 | `resetAccountPassword` sans exclusion `admins`, sans audit, sans révocation de session (uid à double rôle) | **Élevé** (conditionné au double rôle et à un téléphone) |
| R13 | Aucun test de refus d'un uid administrateur dans `passwordReset.test.js` | Moyen |
| R14 | Limitation par appelant seulement (pas par cible/numéro) ; pas de notification au titulaire | Moyen |
| R15 | `fcmTokenCleanup` efface les jetons d'admins sans alerte ; alertes de sécurité dépendantes de `fcmToken` | Moyen |
| R16 | Pilote : fixture super en préproduction, identifiants par défaut non inspectés | Faible à moyen |
| R17 | `guard.js` non appliqué à `firstRun.js`/`financialReport.js` | Faible (pas de connexion) |

## 9. Protections existantes [F]

Liste fermée de types sans `admins` dans `passwordReset.js` ; numéro vérifié = numéro fourni ; recherche unique ; compte supprimé/en fermeture refusé ; limitation 5/h ; `invalid_fcm_tokens` fermé aux clients ; nettoyage limité à `fcmToken` ; `guard.js` : refus par défaut, allow-list, vérification du numéro de projet, confirmation exacte, sortie hors dépôt.

## 10. Recommandations [R]

1. **Autorisation séparée** (fichier protégé) : dans `passwordReset.js`, lire `admins/{uid}` pour chaque cible Auth et refuser si présent (même message générique que pour une cible inexistante), journaliser `logSecurityEvent`; appeler `revokeRefreshTokens` après changement; ajouter `logAudit`; limiter aussi par numéro cible; tests d'exclusion `admins`.
2. Empêcher le **double rôle** admin/non-admin à la création (fonctions L4.11) et inventorier les uid communs (lecture seule autorisée, L4.9).
3. `fcmTokenCleanup` : ne pas modifier les droits, mais journaliser (compteur par collection, dont `admins`) et alerter si le jeton d'un admin actif est effacé; prévoir un second canal d'alerte (e-mail/tableau de bord) indépendant de `fcmToken`.
4. `guard.js` : ajouter l'inspection des identifiants par défaut (compte de service attendu), appliquer la garde à `firstRun.js` si elle devient exécutable, tests d'unité du garde (déjà couverts partiellement) ; conserver l'allow-list unique.
5. Ne pas toucher aux scripts pilotes dans L4.10/L4.11 ; garder la fixture admin de préproduction hors production et documenter son MFA.

## 11. Conditions préalables à L4.10 et L4.11

- **L4.10** : ajouter, avant d'activer ou d'étendre `enforce`, la décision sur la réinitialisation par téléphone (R12) ; vérifier l'état MFA de préproduction ; autorisation distincte pour `passwordReset.js` (hash `26975f60`), `index.js`, `adminPartnerAccounts.js`, `ekbineOrders.js`, `professionalSubscriptions.js`.
- **L4.11** : inventaire des uid à double rôle ; décision « un uid = un rôle » ; détection hors-bande indépendante de FCM ; procédure de récupération d'accès écrite ; les conditions de L4.9 §11 restent valables.
- Aucune mission n'est lancée.

## 12. État Git final

HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, **163 non suivis** (162 + ce rapport). Aucun fichier source, test, règle ou configuration modifié ; aucun secret ouvert ; aucun accès Firebase ; aucun script pilote exécuté ; aucun commit/push/stash/déploiement.

**Fichiers inspectés** : `functions/passwordReset.js`, `functions/fcmTokenCleanup.js`, `scripts/restaurant-v2-pilot/guard.js` (intégraux) ; `functions/index.js` (câblage `resetAccountPassword`, bloc legacy commenté, câblage `fcmTokenCleanupCheck`, écritures `invalid_fcm_tokens`), `firestore.rules` (`invalid_fcm_tokens`), `scripts/restaurant-v2-pilot/lot.js` (constantes, fixture admin), en-têtes et appels de garde des autres scripts pilotes, `functions/test/passwordReset.test.js` (recherche `admin` uniquement), recherches transversales (`sendPasswordResetEmail`, `updateUser`). **Difficultés** : aucune d'accès au dépôt ; production/préproduction inaccessibles par principe ; comportement exact de Firebase (claims téléphone, facteurs après changement de mot de passe) non vérifiable ⇒ marqué [H].

Arrêt : en attente d'une nouvelle autorisation explicite.
