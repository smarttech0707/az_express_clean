# Mission L4.10.5 — Plan technique d'application des décisions L4.10.4

Plan **en lecture seule** : aucun fichier applicatif, test, règle, configuration ou secret modifié ; aucun accès Firebase (production ou préproduction) ; aucun test, build ou déploiement ; rien n'est créé hors de ce rapport. Légende : **[F]** fait vérifié par lecture (fichier:ligne) ; **[H]** hypothèse ou comportement de plateforme **non vérifié ici** ; **[NV]** non vérifiable depuis le dépôt ; **[R]** recommandation. Aucune solution décrite ici n'existe déjà sauf mention **[F]**.

> **Correction d'une erreur de L4.10.4.** Ce rapport affirmait (§2, §6, §11) qu'« aucun mécanisme de version minimale n'existe ». C'était **faux** : ma recherche portait sur des noms (`minAppVersion`, `forceUpdate`…) et a manqué `MinVersionService`. Un mécanisme **partiel** existe (voir §8). Le plan D5 ci-dessous le prend pour base. Le rapport L4.10.4 n'est pas modifié (lecture seule) ; cette note fait foi.

## 1. Résumé des décisions du propriétaire

| Décision | Contenu retenu |
|---|---|
| D2-bis | Option A : connexion par téléphone + mot de passe conservée, **vérification côté serveur**, e-mail réel jamais exposé, comptes existants préservés |
| D2 numéros publics | Étude juridique et métier préalable ; **aucun numéro supprimé ni masqué** ; analyser les appels client → livreur/pharmacie |
| D2 inscription | Réponse uniforme si le numéro est déjà utilisé ; aucune révélation d'existence ; unicité vérifiée côté serveur |
| D3 artisans | OTP obligatoire ; PIN ≥ 6 chiffres ; verrouillage progressif **par profil** ; anti-détournement ; récupération par le support **et** par un administrateur, chaque récupération vérifiée, autorisée et auditée |
| D5 | Mécanisme de version minimale **avant** toute fermeture de règle ; transition de **30 jours** ; étudier le comportement des anciennes versions |
| App Check | Étude séparée ; **hors** de cette mission |

## 2. État technique vérifié

| Sujet | Constat [F] |
|---|---|
| Connexion client | `client_auth_page.dart:140-152` : si l'entrée est un téléphone, `AuthService().getClientAuthEmail` ; échec ⇒ « Numéro de téléphone introuvable » (message distinct d'un mot de passe faux). `:155-170` : `signInWithEmailAndPassword`, puis repli sur `<téléphone>@az-seller.ci` (comptes vendeurs) ; `:174-205` branche vendeur. La même page sert donc **clients et vendeurs**. Une session anonyme est fermée (`signOut`) avant connexion (`:130-133`). |
| `getClientAuthEmail` | `auth_service.dart:25-43` : appelle `checkClientPhone`, utilise `email` si présent, sinon repli `<chiffres>@azexpress.app`. |
| `checkClientPhone` | `index.js:1712-1727` : aucun contrôle `request.auth` ; limite `phone_check_<numéro>` 10/5 min (`:1718`) ; `where('phone','==',phone).limit(1)` — **en cas de doublon, un document arbitraire est retenu** ; renvoie `{exists, email}` (`email` masqué seulement s'il contient `@azexpress.app`). |
| Inscription | `client_auth_page.dart:216-243` : `checkClientPhone` (contrôle d'unicité côté **client**), puis `createUserWithEmailAndPassword` **depuis le client**, puis `clients/{uid}.set` direct (`:244-252`, règle propriétaire `firestore.rules:306-316`, `phone` libre). Course possible entre deux inscriptions concurrentes [déduction du code]. `:258-270` : erreurs `email-already-in-use` (révèle l'e-mail) et `phone-already-in-use`. |
| Fonctions Firebase Auth côté serveur | Aucune occurrence de `createCustomToken`, `signInWithCustomToken`, d'appel REST d'identité (`identitytoolkit`, `signInWithPassword`) dans `functions/` ni `lib/` [F, recherches]. **Émission de jeton personnalisé et vérification de mot de passe côté serveur sont donc des capacités à créer.** |
| Règles de provenance | `isRealUser()` n'exclut que `sign_in_provider == 'anonymous'` (`firestore.rules:80`) ; aucune règle/fonction ne teste `sign_in_provider == 'password'` ou `token.email` [F, recherche]. |
| Artisan | `artisanAccounts.js:12-47` (`artisanLogin`) ; `artisanCredentials.js:62` et `passwordReset.js:73` (`/^\d{4,6}$/`) ; `artisanPhotos.js:47,76,99` (autorisation par `artisanUid === request.auth.uid`) ; `artisan_login.dart:36-65` (reprise automatique par `SharedPreferences` **sans appel serveur**), `:96-106` (appel `artisanLogin`) ; règle `service_providers` `firestore.rules:1289-1331`. |
| Version minimale | voir §8. |
| Versions et canaux | `pubspec.yaml:4` `1.0.10+11` ; `pubspec.yaml:52` `url_launcher` ; ni `package_info_plus`, ni `firebase_remote_config`, ni `in_app_update` dans `pubspec.yaml` ; `firebase_app_check` présent (`:88`) mais **non appliqué** côté fonctions. `docs/DISTRIBUTION_ANDROID.md` : Google Play (AAB 1.0.6→1.0.9 non suivis à la racine, 1.0.10+11 « réservé à Google Play ») **et** APK direct `/telecharger` (1.0.9, signature différente de Play), Android 7.0/API 24 minimum ; iOS : `IPHONEOS_DEPLOYMENT_TARGET = 13.0` (`project.pbxproj`), guides Mac/Apple ; le web se met à jour au déploiement. |

## 3. Analyse D2-bis — nouvelle connexion client (option A)

### 3.1 Principe [R]
Callable `clientPhoneLogin({identifier, password})` : le serveur résout le compte, **vérifie le mot de passe**, puis renvoie un **jeton personnalisé** Firebase que l'application échange (`signInWithCustomToken`). L'e-mail ne quitte jamais le serveur. L'entrée e-mail directe reste telle quelle (aucune fuite : l'utilisateur fournit lui-même l'e-mail).

### 3.2 Faisabilité réelle (points à valider, aucun supposé acquis)
1. **Vérification du mot de passe côté serveur.** Le SDK Admin n'expose pas de vérification de mot de passe [H, comportement connu de la plateforme]. Voie standard : appel REST « sign in with password » de Firebase Authentication avec la **clé API Web du projet** (identifiant public déjà présent dans la configuration de l'application ; **aucune lecture ni création de secret dans cette mission**). Cette clé devra être fournie à la fonction par configuration [NV : non présente dans `functions/` aujourd'hui]. Alternatives écartées : renvoyer l'e-mail (la fuite), ou un jeton d'ID/rafraîchissement (non utilisable par le SDK client).
2. **Émission du jeton.** `createCustomToken` exige que le compte de service d'exécution puisse signer (rôle « Service Account Token Creator » sur lui-même) [H, exigence de la plateforme ; non vérifiée sur ce projet, **à tester d'abord en préproduction ou émulateur avec identifiants simulés**].
3. **Session obtenue.** Un jeton personnalisé crée une session sur le **même uid** (comptes existants préservés) avec fournisseur `custom` [H]. Compatibilité avec le code existant : les règles n'excluent que `anonymous` [F] ; `reauthenticateEmail(user.email!, …)` (`auth_service.dart:~116`, `updatePhone`) suppose `currentUser.email` renseigné — à confirmer après connexion par jeton personnalisé [H]. Les revendications personnalisées de l'utilisateur (ex. `partnerMustChangePassword`, utilisée par l'activation partenaire) devraient être reprises dans le jeton d'ID [H, à tester].
4. **Sessions existantes.** L'émission d'un nouveau jeton ne révoque **pas** les sessions déjà ouvertes [H] ; aucune action sur les sessions existantes n'est requise par ce plan.
5. **Une session anonyme n'est pas une authentification** : la callable est appelée avec une session anonyme (état de pré-connexion) ; elle ne doit **jamais** y voir une preuve. Les protections reposent sur les limites, la réponse uniforme et, ultérieurement, App Check (étude séparée).

### 3.3 Résolution du compte (comptes existants préservés)
Le serveur reproduit **les mêmes candidats que le client aujourd'hui** : (1) `clients.email` réel du document unique pour ce numéro ; (2) alias historique `<chiffres>@azexpress.app` ; (3) alias vendeur `<téléphone>@az-seller.ci` [F, `auth_service.dart:25-43` et `client_auth_page.dart:160-166`]. Il renvoie, après succès seulement, le **rôle** (client ou vendeur) pour que l'écran choisisse la suite (équivalent de `isSeller`). Doublons de numéro (plusieurs `clients`) : échec uniforme + événement d'anomalie (au lieu du choix arbitraire de `limit(1)`).

### 3.4 Erreurs, temporisation, abus
- **Une seule erreur** pour inconnu / mot de passe faux / compte fermé / doublon / jeton impossible (« Identifiants incorrects »). Le texte « Numéro de téléphone introuvable » (`client_auth_page.dart:147`) disparaît.
- **Temps de réponse** : mêmes étapes pour tous les cas (vérification fictive pour un inconnu) et plancher de latence.
- **Force brute / déni de service** : trois compteurs `checkRateLimit` (par appelant, par couple numéro+appelant, par numéro) ; sur le compteur **par numéro**, un **ralentissement** (délai croissant), **jamais un verrou dur** qui permettrait à un tiers de bloquer le titulaire. Le comportement de limitation propre à Firebase Authentication (`TOO_MANY_ATTEMPTS_TRY_LATER`) existe déjà sur l'accès direct par e-mail [H] et subsiste.
- **Surveillance** : `security_events` à seuil (empreinte du numéro, jamais le numéro en clair).

### 3.5 Compatibilité pendant la transition (30 jours)
`checkClientPhone` conserve son **contrat actuel** dans un mode de compatibilité temporaire pour les anciennes versions (sinon leur connexion par téléphone casse — `auth_service.dart:25-43`), puis bascule en réponse neutre à la fin de la transition (§9). Le mode est une valeur de configuration à liste fermée (valeur inconnue = erreur de configuration, pas repli silencieux ; leçon de `ADMIN_MFA_MODE`). **La fuite d'e-mail persiste donc pendant la transition** : mesure compensatoire minimale proposée, soumise à décision (Q3) : limites strictes par appelant et par numéro, sans changer la forme de la réponse.

### 3.6 Tests à prévoir
Unitaires (fonction avec dépendances injectées) : succès téléphone, succès repli `azexpress.app`, succès repli vendeur, mot de passe faux, numéro inconnu, doublon, compte fermé/tombstone, réponses octet-identiques, plancher de latence, compteurs. Intégration (émulateur Auth `demo-*`) : jeton personnalisé → session sur le même uid ; `email` du `currentUser` ; revendications ; refresh. Compatibilité : ancienne version vs nouvelle fonction, nouvelle version vs ancienne fonction. Flutter : écran de connexion avec crochet de test.

## 4. Analyse D2 — inscription et unicité

**Constat [F]** : l'unicité est vérifiée **côté client** avant `createUserWithEmailAndPassword` (`client_auth_page.dart:228-235`) puis le profil est écrit directement ; aucune contrainte serveur ; course et doublons possibles ; `limit(1)` choisit arbitrairement un doublon (`index.js:1721`) ; `email-already-in-use` révèle l'existence d'un e-mail.

**Conception [R].** Callable `registerClient({name, phone, email, password})` :
- Transaction qui **réserve le numéro** (document de réservation à identifiant dérivé du numéro par HMAC à clé serveur — idée du registre `account_phone_bindings`, validée seulement en hypothèse, **non créé**), crée le compte Auth via le SDK Admin, écrit `clients/{uid}` (Admin SDK, `wallet:0`) et valide la réservation ; échec ⇒ compensation (suppression du compte créé, libération). Remplace l'écriture client directe (la règle `clients.create` ne se ferme qu'après la période de transition).
- **Concurrence** : la réservation est une création unique (échec si existante) : un seul gagnant.
- **Réponse uniforme.** Limite fondamentale à trancher (Q4) : si l'inscription renvoie une **session** en cas de succès, un numéro déjà pris ne peut pas produire exactement la même réponse sans prouver la possession du numéro. Deux options : (a) **OTP du numéro avant toute information** (la divulgation « déjà utilisé » ne concerne alors que le titulaire du numéro) — dépend de Phone Auth (panne signalée `INTERNAL (13) / 39` dans `forgot_password_page.dart`, état actuel [NV]) et de son coût ; (b) réponse strictement identique « demande reçue, connectez-vous ou récupérez votre accès », **sans connexion automatique** — uniforme mais dégrade l'expérience.
- **Temps** : mêmes opérations pour numéro libre et pris (travail équivalent, plancher de latence).
- **Anciens comptes/doublons** : inventaire à blanc ultérieur ; les doublons existants sont classés anomalies, aucune fusion ni blocage automatique ; la réservation ne couvre que les **nouvelles** inscriptions tant que la migration du registre n'est pas autorisée.
- **E-mail** : l'erreur `email-already-in-use` reste une divulgation (comportement Firebase) [H : dépend du paramétrage « protection contre l'énumération d'e-mails » du projet, non vérifiable ici].
- **Tests** : inscriptions concurrentes (N en parallèle, un seul succès, aucun compte orphelin), numéro libre vs pris (réponses identiques, temps comparables), échec en milieu de transaction (compensation), doublons historiques, ancienne version, e-mail déjà pris.

## 5. Numéros publics — étude technique et fonctionnelle (aucun numéro supprimé ni masqué)

**Collections lisibles par tout utilisateur connecté, anonymes compris [F, `firestore.rules`]** : `livreurs` (`:369`), `pharmacies` (`:566`), `service_providers` (`:1292`), `boulangeries` (`:527`), `ekbine_agents` (`:962`), `locations`, `residences` (`:1334-1342`), `simple_services` (projection publique avec `phone`, `:1507-1515`), `pharmacy_guards` (lecture authentifiée des gardes actives). Non publique : `sellers` (propriétaire ou admin), `clients`, `fleet_owners`, `real_estate_agents`.

**Écrans et usages d'appel (`tel:`) [F, recherche `lib/`]** : suivi de commande (appel livreur) `suivi_commande.dart:154`, `eta_card.dart:67` ; garde de pharmacie `pharmacie_garde.dart:300` ; annuaire artisans `service_providers_page.dart:149` ; services simples `simple_service_page.dart:29` ; locations/résidences `locations_page.dart:477`, `residences_page.dart:658` ; marketplace `mp_chat_page.dart:324`, `mp_product_detail.dart:470` ; tableaux de bord livreur `driver_dashboard.dart:445`, vendeur `seller_dashboard.dart:1394,1535`, boulangerie `boulangerie_dashboard.dart:691,751`, pharmacie `pharmacie_dashboard.dart:949` ; support `support_screen.dart:408`. Ceux qui lisent un numéro **dans la commande** ou **dans le profil public** ne sont pas tous distingués [NV : lecture des écrans non faite un par un].

**Conséquences d'une restriction [déduction]** : l'appel client → livreur et client → pharmacie/artisan/boulangerie est direct depuis le document public ; toute restriction casse ces boutons tant qu'une alternative n'existe pas.

**Alternatives à étudier (non retenues, non implémentées)** : (1) numéro exposé uniquement aux **participants d'une commande active** (callable qui renvoie le numéro au client concerné, audité) ; (2) numéros d'**établissement** distincts des numéros **personnels** (livreur) ; (3) appel/chat **dans l'application** ou numéro intermédiaire (fournisseur de téléphonie : coût, couverture) ; (4) statu quo documenté avec consentement explicite.

**Questions juridiques et de consentement (validation humaine)** : base légale de la publication des numéros des livreurs (personnes physiques) et de leur exposition à des comptes anonymes ; consentement recueilli à l'inscription (textes de `confidentialite.html` à relire) ; distinction numéro professionnel/personnel ; droit d'opposition et de retrait ; durée de conservation ; conformité avec la législation ivoirienne de protection des données [H : à confirmer par un juriste] ; information des artisans/pharmacies ; responsabilité en cas d'usage abusif (démarchage, harcèlement, échange de carte SIM).

## 6. Architecture D3 — artisans

### 6.1 Constats [F]
- `artisanLogin` (`artisanAccounts.js:12-47`) exige `request.auth` (anonyme accepté), cherche jusqu'à 10 profils par numéro (`:17`), vérifie le PIN haché (`artisan_credentials`) ou le PIN en clair hérité, puis **réécrit `artisanUid` avec l'uid de l'appelant s'il diffère** (`:30-32`). Limite `artisan_login_<numéro>` 10/300 s (`:16`).
- La « session » artisan = uid anonyme mémorisé dans `artisanUid` ; l'application reprend sans appel serveur à partir de l'identifiant de document sauvegardé (`artisan_login.dart:44-65`). Le seul pouvoir protégé par `artisanUid` est la gestion des **photos** (`artisanPhotos.js:47,76,99`) [F, deux appels de fonction dans `artisan_dashboard.dart`].
- Règle de réclamation directe : `firestore.rules:1326-1331` (n'importe quel utilisateur réel pose son uid si absent).
- PIN : `/^\d{4,6}$/` dans `artisanCredentials.js:62` (utilisé par `setPin`, donc `setArtisanPin` et la réinitialisation) et `passwordReset.js:73` (fichier **protégé**).
- `setArtisanPin` (`artisanAccounts.js:50-56`) : tout administrateur ayant la permission `services` peut fixer le PIN de **n'importe quel artisan** sans preuve ni seconde validation ; l'administrateur **connaît** le PIN qu'il fixe. Audit minimal dans la transaction (`artisanCredentials.js:~90-95`).
- Profils hérités : `planDocument` (`artisanCredentials.js:12-27`) distingue `needs_migration` (PIN en clair), `resume_cleanup`, `anomaly` (`invalid_credential`, `invalid_legacy`, `credential_mismatch`, `missing_credential`), `clean`. Leur **nombre réel est inconnu** [NV].

### 6.2 Parcours cible [R] (aucune fonction ni collection créée par cette mission)
1. **Identification** : numéro saisi ; résolution **uniforme** (pas de message distinct) ; si plusieurs profils pour le numéro ⇒ échec uniforme + file de revue (au lieu de la boucle sur 10 candidats).
2. **PIN** : vérification à temps constant du haché ; PIN **≥ 6 chiffres** pour tout nouveau PIN. Les PIN existants de 4–5 chiffres ne sont pas détectables (seul le haché est stocké) : lors d'un login réussi le serveur connaît la saisie et peut marquer `pinMustChange` ; changement exigé après OTP (jamais de liaison automatique).
3. **OTP** : preuve de possession **récente** du numéro. Précaution majeure : lier le crédit téléphonique à la session anonyme de l'artisan (`linkWithCredential`) ferait du **téléphone un moyen de connexion** pour cet uid (recyclage de numéro ⇒ prise de profil ; contraire au principe D6 retenu). Option [H, à valider] : obtenir le jeton OTP sur une **instance Firebase secondaire** de l'application, le transmettre dans la requête et le faire vérifier par le serveur (`verifyIdToken`), sans modifier la session principale. Dépendance : Phone Auth fonctionnel [NV].
4. **Liaison** : transaction unique sur le profil et son état de réclamation (version, `claimId`, précondition « `artisanUid` inchangé ») ; une réclamation sur un profil **déjà lié à un autre uid** devient une **reprise** (PIN + OTP + délai + notification), jamais un écrasement.
5. **Deux réclamations simultanées** : la version du document d'état fait échouer la seconde (erreur uniforme).
6. **Verrouillage progressif par profil** (compteur persistant par profil, pas par numéro) : par exemple 5 échecs ⇒ 1 min, 7 ⇒ 30 min, 10 ⇒ 24 h ; la session déjà liée n'est pas affectée ; levée par le support/administrateur ; paramètres à valider.
7. **Notification du titulaire** (quand possible) : FCM vers le jeton enregistré du profil (`saveToken` vers `service_providers`) + journal consultable ; sinon appel du support au numéro enregistré. Les artisans n'ont pas de canal e-mail [F, formulaire d'inscription].
8. **Journalisation** : chaque tentative (succès, refus, verrou, reprise, récupération) dans `audit_logs` et `security_events` avec empreintes, jamais PIN ni numéro en clair.
9. **Règles** : après la période de transition, retirer la branche de réclamation directe (`:1326-1331`) et la branche `photos` devenue inutile (`:1329-1331`) — **non fait ici**.
10. **Sessions** : l'uid anonyme reste le support de la session ; recommandation [R, D6] de ne pas en faire une identité durable ; à étudier : session liée à un jeton personnalisé révocable [H, dépend du même acquis technique que D2-bis].

## 7. Procédures de récupération artisan

**Preuves disponibles [F/NV]** : le dossier d'artisan contient nom, téléphone, adresse, description, photos (`serviceProviderApplication.js`, champs vus) ; **aucune pièce d'identité** n'est collectée [déduction : absence des champs dans les extraits lus ; à confirmer].

**Preuves exigées [R]** : (1) OTP du numéro enregistré ; (2) vérification de connaissance des données du dossier (non devinables publiquement : ce qui est public — nom, téléphone, photos — ne compte pas) ; (3) **rappel par le support au numéro enregistré** ; (4) pour les cas sensibles, vérification en personne à Abengourou (pièce d'identité contrôlée, **non conservée dans le système**) ; justificatifs : référence de dossier + empreinte, pas de copie dans Firestore.

**Rôles [R]** : le **support** (permission existante `support`, `firestore.rules` liste des permissions) **ouvre** la demande et collecte les preuves ; un **administrateur** (permission `services` ou super) **approuve** ; l'exécuteur est une fonction serveur, pas l'écran. **Double validation** (second administrateur distinct, jamais le demandeur ni l'approbateur initial) pour : profil déjà lié à un autre appareil, numéro changé récemment, profil vérifié/à fort volume, contestation en cours, demande hors heures.

**Ce que l'administrateur ne peut pas faire** : choisir ou connaître le PIN du titulaire ; modifier `phone` ; réaffecter le profil à un autre appareil sans passer par une demande tracée. Le mécanisme existant `setArtisanPin` (PIN choisi par l'administrateur) est **à remplacer** par : l'administrateur autorise une **session de récupération à usage unique**, puis le **titulaire** choisit son nouveau PIN après OTP.

**Contestation et retour** : fenêtre de 72 h pendant laquelle le titulaire précédent est notifié et peut contester ; l'ancien lien est conservé (statut « suspendu ») pour restauration ; tout changement est réversible par une décision tracée.

**Audit** : demandeur, preuves (références), approbateur(s), horodatage serveur, résultat ; journal non modifiable par le client ; alertes sur volumes anormaux de récupérations.

**Profils hérités / ambigus** (PIN en clair, PIN absent, credential invalide ou en conflit, doublons de numéro) : **aucune liaison ni migration automatique** ; file de revue humaine ; migration du PIN seulement au premier login réussi après OTP.

## 8. Architecture D5 — version minimale

### 8.1 Ce qui existe déjà [F]
- Document `config/app_versions`, lisible de **tous, y compris non authentifiés** (`firestore.rules:1490-1491`), écriture super-admin (`:1495`) ; forme `{ <rôle>: { minBuild, enforce, message } }`.
- `MinVersionService.evaluate/check` (`min_version_service.dart:15-47`) ; statut `ok | updateRecommended | updateRequired` ; **échec réseau ⇒ `ok`** (jamais bloqué hors connexion).
- Numéro de build lu de `--dart-define=APP_BUILD_NUMBER` (`min_version_service.dart:6`) ; **valeur 0 = inconnue ⇒ jamais bloqué** ; **aucune trace de ce paramètre dans les scripts de build** (recherche `*.py`, `*.yml`, `*.json`, `*.ps1`, `*.sh`) ; seule la documentation le mentionne (`docs/DELIVERY_TRANSFER.md`). Les builds publiés déclarent donc probablement 0 [H : scripts non exécutés, builds non inspectés].
- Branchements : livreur (`driver_dashboard.dart:82,1492-1514`), client (`client_dashboard.dart:74-76`), restaurateur (`restaurant_owner_dashboard.dart:65`) ; vérification séparée avant paiement wallet (`config/app_version.minWalletPaymentBuild`, `wallet_payment_compatibility.dart:~48-58`, 8 appels). **Non branchés** : vendeur, boulangerie, pharmacie, artisan, flotte, E-Kbine, agent immobilier, administrateur.
- Dates (historique Git) : contrôle wallet depuis le 2026-09-17 (`e4228cf`) ; restaurateur/client depuis le 2026-11-04 (`00d98ee`). Les builds antérieurs (par exemple 1.0.6→1.0.9) **ne peuvent pas être bloqués** pour ces rôles [H, d'après les dates de commit et la date du build 1.0.6+7 de 2026-10-07].
- `min_version_dialog.dart` : en mode obligatoire, la boîte **n'a aucun bouton** (`actions` vide si `required`) : l'utilisateur est bloqué sans moyen d'ouvrir la boutique [F].
- Aucun suivi des versions en usage, aucun contrôle serveur de version [F].

### 8.2 Limite structurelle [R/H]
Les règles Firestore **ne voient pas la version** de l'application : le contrôle de version est une **barrière d'expérience** (et de callables si la version est transmise, valeur déclarative falsifiable), **pas une frontière de sécurité**. La protection effective vient de la fermeture des règles ; la version minimale sert à y préparer les utilisateurs. Les versions qui **ne contiennent pas** le mécanisme (ou déclarent 0) ne peuvent être prévenues que par l'échec de leurs écritures.

### 8.3 Architecture complète [R]
- **Version installée** : numéro de build injecté à la compilation (existant) rendu **obligatoire** dans les scripts de build ; en alternative, `package_info_plus` (nouvelle dépendance, décision à part). Version affichée dans les réglages.
- **Comparaison** : `config/app_versions` étendu par rôle **et plateforme** (`android`, `ios`, `web`) avec `minBuild`, `recommendedBuild`, `enforce`, `message`, `storeUrl`/`downloadUrl`, `enforceAfter` (date de début de blocage).
- **Recommandée vs obligatoire** : statuts existants conservés ; ajout d'une date `enforceAfter` pour le basculement planifié sans nouveau déploiement.
- **Android** : Google Play — mise à jour dans l'application possible via l'API Play (« flexible »/« immédiate »), qui n'est disponible que pour les installations issues de Play [H] et exige un plugin absent de `pubspec.yaml` ; installations **APK directes** (`/telecharger`, autre signature) : lien de téléchargement, pas de mise à jour automatique [F/H]. Détecter la source d'installation est nécessaire pour afficher le bon lien [H, API de la plateforme].
- **iOS** : aucune API de mise à jour dans l'application ; ouvrir la fiche App Store par `url_launcher` (déjà présent) [F/H]. L'état de publication de l'application sur l'App Store n'est pas établi dans le dépôt [NV].
- **Web** : mise à jour au déploiement ; risque de cache du service worker [H] — hors périmètre.
- **Utilisateurs qui ne peuvent pas mettre à jour** (appareil trop ancien — Android < 7.0, iOS < 13 — espace disque, pas de Play) : message spécifique, support, possibilité de maintenir un mode lecture (décision Q8).
- **Suivi** : à la connexion, report anonymisé `{role, platform, build}` agrégé côté serveur (fonction, compteurs) ; tableau de bord administrateur des parts par version ; alertes quand la part des versions < minimale dépasse un seuil à J-7.
- **Dialogue obligatoire** : doit comporter un bouton « Mettre à jour » (corrige la lacune §8.1).
- **Roles non couverts** : étendre à tous les rôles dont les écritures seront fermées.

## 9. Calendrier de la transition de 30 jours

| Élément | Proposition [R] |
|---|---|
| **Point de départ T0** | Jour où la version **contenant le mécanisme complet** (build injecté, bouton de mise à jour, rôles couverts) est **disponible sur tous les canaux utilisés** : Play (déploiement à 100 %), App Store (approuvée) si applicable, page `/telecharger`. Pas de décompte tant qu'un canal est en retard. |
| **Versions concernées** | Toutes les versions de build < `minBuild` de T0, par rôle et plateforme ; builds déclarant 0 **non bloquables** (traitées par l'échec des écritures). |
| **J0 (T0)** | `enforce:false`, message « mise à jour disponible » ; communication aux utilisateurs et aux administrateurs. |
| **J+7 / J+14 / J+21** | Rappels dans l'application, notifications push, annonce support ; rapport hebdomadaire de la part des versions anciennes. |
| **J+23 (J−7)** | Alerte aux administrateurs : part restante ; décision de maintien/report. |
| **J+30** | `enforce:true` rôle par rôle (artisans et administrateurs d'abord, clients ensuite) ; **les fermetures de règles ont lieu après**, par mission distincte et déploiement distinct. |
| **Fin de transition `checkClientPhone`** | Passage en réponse neutre seulement après `enforce:true` du rôle client et vérification des parts résiduelles. |
| **Hors connexion** | Échec réseau ⇒ pas de blocage (existant) ; **risque** : écritures Firestore en file d'attente d'un ancien client rejetées après fermeture de règle (échec `permission-denied` silencieux) [H]. Communication : se connecter avant J+30. |
| **Retour arrière** | Abaisser `minBuild`/remettre `enforce:false` (config, effet à la prochaine lecture) ; repousser `enforceAfter` ; pour les règles : redéploiement de la version précédente (artefact conservé), sans rouvrir volontairement une faille critique sans décision écrite et mesure compensatoire (limites strictes, support). |

## 10. Ordre des futures missions (chacune nécessite sa propre autorisation)

| N° | Mission future | Dépend de | Remarque |
|---|---|---|---|
| M0 | Décisions Q1–Q10 (§15) | — | prérequis |
| M1 | **Vérifications de faisabilité hors production** : jeton personnalisé (émulateur/identifiants simulés), REST mot de passe, comportement de session, `package_info`/source d'installation, instance Firebase secondaire pour l'OTP | M0 | résultats avant tout code |
| M2 | **Version minimale complète** (scripts de build, bouton, couverture des rôles, suivi) | M0 | **avant toute fermeture** ; indépendant de M3–M5 |
| M3 | `clientPhoneLogin` + écran de connexion + mode de compatibilité de `checkClientPhone` | M1 | `index.js` protégé |
| M4 | `registerClient` (unicité, réponse uniforme) | M1, Q4 | idem |
| M5 | Artisans : réclamation, PIN ≥ 6, verrou par profil, OTP, récupération support/admin | M1, Q5–Q7 | touche `passwordReset.js` (protégé) pour le PIN |
| M6 | Étude juridique des numéros publics (documentaire) | — | pas de code |
| M7 | Approbations vendeurs/livreurs et changement de téléphone (L4.10.4) | M2 | non traité ici |
| M8 | Période de transition de 30 jours (opérationnel) | M2–M5 déployés | calendrier §9 |
| M9 | Fermetures de règles par collection (une par une) | M8, M7 | déploiements séparés |
| M10 | Inventaire à blanc → revue → registre | décisions D6–D8 | |
| — | App Check | étude séparée | non inclus |

## 11. Fichiers concernés (par mission)

M2 : `scripts/build_mobile.py` (et scripts de build associés), `lib/services/min_version_service.dart`, `lib/widgets/min_version_dialog.dart`, tableaux de bord de chaque rôle, fonction de rapport de versions (nouvelle), `config/app_versions` (données), `firestore.rules` (**non touchée** tant que M9). M3 : `functions/index.js` (protégé), nouveau module `functions/clientAuth.js`, `lib/services/auth_service.dart`, `lib/screens/auth/client_auth_page.dart`, `lib/web/web_client_auth.dart` (parcours web à examiner, [NV]). M4 : mêmes + règle `clients` (fermeture ultérieure). M5 : `functions/artisanAccounts.js`, `artisanCredentials.js`, `artisanPhotos.js`, `passwordReset.js` (protégé), `lib/screens/artisan/artisan_login.dart`, `artisan_dashboard.dart`, `lib/services/artisan_account_service.dart`, `admin_services_page.dart`, règle `service_providers` (ultérieure). Tests correspondants dans `functions/test/` et `rules-tests/`. **Fichiers jamais touchés sans accord** : `feexpayPayments.js`, `orderRefunds.js` et les cinq fichiers sensibles.

## 12. Risques et dépendances

- **Techniques** : émission de jeton personnalisé non validée sur ce projet ; clé API Web à fournir à la fonction ; compatibilité `reauthenticateEmail` après connexion par jeton ; Phone Auth en panne signalée [NV] (bloque OTP artisan et option (a) d'inscription) ; instance Firebase secondaire à valider.
- **Produit** : la fuite d'e-mail subsiste pendant la transition (compatibilité) ; l'inscription strictement uniforme dégrade l'expérience sans OTP ; PIN ≥ 6 impose un changement aux artisans existants.
- **Opérationnels** : builds sans `APP_BUILD_NUMBER` non bloquables ; trois canaux Android/iOS à synchroniser ; versions < mécanisme sans possibilité d'avertissement ; écritures hors connexion rejetées après fermeture.
- **Juridiques** : numéros publics, données de contact des livreurs, traitement des pièces d'identité en récupération artisan.
- **Sécurité résiduelle** : session anonyme comme identité artisan ; super-admins et propriétaires GCP gardent un pouvoir de contournement ; App Check non appliqué.

## 13. Critères d'acceptation (mesurables)

| Chantier | Critère |
|---|---|
| D2-bis | 0 e-mail dans toute réponse/journal de `clientPhoneLogin` ; 100 % des comptes de test (téléphone, alias, vendeur) se connectent ; réponses d'échec octet-identiques ; écart de temps inconnu/connu sous un seuil fixé (par exemple 50 ms de médiane) |
| Inscription | 50 inscriptions concurrentes du même numéro ⇒ 1 compte, 0 orphelin ; numéro libre/pris indiscernables selon l'option choisie |
| `checkClientPhone` neutre | après T0+30 : réponse identique pour tout numéro ; 0 e-mail ; anciennes versions : comportement documenté |
| Artisans | PIN < 6 refusé ; 5e échec ⇒ verrou ; deux réclamations parallèles ⇒ 1 gagnant ; reprise exige PIN+OTP+délai ; toute récupération laisse une trace complète |
| Version minimale | 100 % des builds de test déclarent un numéro ≠ 0 ; bouton de mise à jour présent ; rôles de la liste couverts ; suivi des versions disponible ; retour arrière testé |
| Global | 0 régression financière (suite de référence ≥ 2875 tests / 0 échec) ; 0 règle fermée avant fin de transition |

## 14. Tests à prévoir ultérieurement

Unitaires : connexion, inscription, verrouillage, validation du PIN, comparaison de versions (`evaluate`), compatibilité. Cloud Functions : fonctions de connexion/inscription/réclamation/récupération avec dépendances injectées. Émulateur Auth+Firestore (`demo-*`, un lot à la fois) : jeton personnalisé, unicité concurrente, verrou, journaux. Règles : inchangées en M2–M8 ; matrice de fermeture en M9. Flutter : écrans de connexion, inscription, artisan, dialogue de version avec crochets. Web : parcours de connexion web. Concurrence, idempotence, anciennes versions (matrice build × fonction), hors connexion (file d'écritures), comptes fermés/multiprofils, non-régression financière. Aucun test n'est lancé dans cette mission.

## 15. Questions restant à trancher

1. Accepter la création de `clientPhoneLogin` avec **clé API Web fournie en configuration** et la nécessité d'un rôle de signature pour les jetons personnalisés (validation de faisabilité d'abord) ?
2. Pendant la transition, conserver le contrat actuel de `checkClientPhone` (fuite d'e-mail) ou imposer une mesure compensatoire plus stricte (au risque de casser les anciennes versions) ?
3. Mesure compensatoire minimale acceptable pendant 30 jours (limites par appelant et par numéro) ?
4. Inscription : OTP avant toute information, ou réponse uniforme sans connexion automatique ?
5. Artisans : valeurs du verrou progressif, durée de la fenêtre de contestation (72 h ?), double validation pour quels cas ?
6. Artisans : qui est le « support » (personnes, permission `support`) et qui approuve (permission `services`, super) ? Vérification en personne obligatoire pour quels cas ?
7. PIN ≥ 6 : changement forcé au prochain login pour tous les artisans ?
8. Utilisateurs sur appareils non mis à jour : maintien d'un mode lecture ou blocage total ? Appareils < Android 7.0 / iOS 13 ?
9. Origine de T0 : quels canaux doivent être à jour (Play, App Store, APK direct) et quel suivi de part de version est accepté ?
10. Dépendances nouvelles autorisées (`package_info_plus`, `in_app_update`) ou conservation du numéro de build injecté ?
11. Numéros publics : qui mène l'étude juridique, et quel arbitrage entre appel direct et alternatives (§5) ?
12. Statut réel de Phone Auth en production et de l'App Store (iOS) à fournir par le propriétaire.

## 16. Autorisations distinctes nécessaires

Une autorisation **par mission** : M1 (vérifications hors production), M2 (version minimale, modifications Flutter et scripts de build), M3 et M4 (`index.js` protégé, `auth_service.dart`, `client_auth_page.dart`), M5 (dont `passwordReset.js` protégé), M7, M9 (règles, **déploiement distinct**), M10 (lecture de données). Aucun déploiement, commit, push, migration, configuration (`config/app_versions`, variables d'environnement) ni activation d'App Check, de suppression de compte ou de FeexPay n'est autorisé par ce plan. Aucune autorisation globale ne doit être déduite de ce rapport.

## 17. Compte rendu final

- **Fichiers consultés** : `auth_service.dart`, `client_auth_page.dart`, `artisan_login.dart`, `artisan_account_service.dart`, `min_version_service.dart`, `min_version_dialog.dart`, `wallet_payment_compatibility.dart`, `client_dashboard.dart`, `driver_dashboard.dart` (extraits), `artisanAccounts.js`, `artisanCredentials.js`, `artisanPhotos.js`, `index.js` (`checkClientPhone`, recherches), `passwordReset.js` (ligne PIN), `firestore.rules` (blocs cités), `pubspec.yaml`, `docs/DISTRIBUTION_ANDROID.md`, historique Git (lecture seule : dates d'introduction), rapports L4.10.1 → L4.10.4.
- **Erreur reconnue** : l'inexistence d'un mécanisme de version minimale (L4.10.4) était fausse ; corrigée en §8.
- **Éléments non vérifiables** : capacités Firebase (jeton personnalisé, REST mot de passe, sessions), état de Phone Auth, builds publiés (valeur de `APP_BUILD_NUMBER`), App Store, données réelles, écrans web non lus, texte des consentements.
- **Git** : avant — HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 168 non suivis ; après — voir le message final de la conversation.
- Aucun test, build ou déploiement lancé ; aucun fichier applicatif, de règle ou de configuration modifié ; aucun accès Firebase.

Arrêt : attente d'une autorisation explicite pour chaque mission d'implémentation.
