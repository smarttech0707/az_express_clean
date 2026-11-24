# Mission L4.10.4 — Plan de remédiation priorisé et décisions de sécurité

Planification en **lecture seule** : aucun code, test, règle, configuration ou secret modifié ; aucune donnée Firebase lue ou écrite ; aucune implémentation. Légende : **[F]** fait confirmé par lecture ; **[H]** hypothèse ; **[NV]** non vérifiable ici ; **[R]** recommandation.

## 1. Synthèse exécutive

Six chantiers, dont **deux P0**. Constat structurant découvert en préparant ce plan : **la correction de `checkClientPhone` ne peut pas être un simple retour neutre**, car l'application s'en sert pour la **connexion par téléphone** : `AuthService.getClientAuthEmail` appelle la fonction, récupère l'e-mail réel et s'en sert pour `signIn` (repli sur `<numéro>@azexpress.app` pour les anciens comptes) [F, `auth_service.dart:25-43`] ; l'inscription l'utilise aussi pour refuser un numéro déjà pris (`client_auth_page.dart:232`) [F]. Corriger la fuite exige donc de **remplacer le mécanisme de connexion par téléphone** avant de rendre la fonction neutre. De plus, l'exigence d'authentification est peu protectrice : les clients mobiles sont **anonymes par défaut** [F, charte], donc `request.auth` existe presque toujours.

Ordre recommandé : (0) décisions ; (1) P0-A `checkClientPhone` (avec nouveau mécanisme de connexion) ; (2) P0-B réclamation artisan ; (3) fonctions d'approbation vendeurs/livreurs ; (4) changement de téléphone serveur ; (5) fermeture progressive des règles ; (6) inventaire à blanc → revue → registre. Les étapes 1 et 2 sont **indépendantes** entre elles et de toutes les suivantes ; 3 doit précéder la fermeture des créations ; 4 précède la fermeture des écritures directes de `phone`.

## 2. Sources examinées

Rapports complets : `ACCOUNT_DELETION_L4_10_PASSWORD_RESET_DUAL_ROLE_AUDIT.md`, `…L4_10_1_PASSWORD_RESET_REMEDIATION_DESIGN.md`, `…L4_10_2_SELLERS_PHONE_BINDING_AUDIT.md`, `…L4_10_3_IDENTITY_PATHS_AUDIT.md` (noms réels confirmés, aucun doublon créé). Code relu pour ce plan : `lib/services/auth_service.dart`, `lib/screens/auth/client_auth_page.dart`, `functions/artisanAccounts.js`, `lib/screens/admin/driver_requests_page.dart`, `admin_seller_requests_page.dart`, `functions/index.js` (`checkClientPhone`, commentaires `artisanLogin`), `firestore.rules` (blocs déjà lus en L4.10.x). Aucun mécanisme de **version minimale d'application** n'a été trouvé (recherche `minAppVersion`, `forceUpdate`, etc.) [F] : le contrôle de compatibilité avec d'anciennes versions repose aujourd'hui sur rien d'automatique.

## 3. Vulnérabilités prioritaires

| Rang | Id | Vulnérabilité | Statut | Gravité |
|---|---|---|---|---|
| P0 | V4 | `checkClientPhone` : appel sans authentification contrôlée, existence du numéro + e-mail réel | Confirmé | Élevé |
| P0 | V5/V7 | `service_providers` : réclamation libre (`artisanUid`), PIN 4–6 chiffres, `artisanLogin` rattache l'`artisanUid` à tout appelant qui connaît numéro + PIN | Confirmé | Élevé |
| P1 | V9 | Approbations vendeur/livreur par transaction/lot **client**, données de la demande non vérifiées | Confirmé | Moyen |
| P1 | V1–V3, V12 | Écriture directe de `phone` (sous-admin, titulaire, super), reset par `profile.phone` | Confirmé | Élevé |
| P2 | V10 | Aucune exigence MFA sur les écritures de profils par le super-admin | Confirmé | Élevé |
| P2 | V6, V8 | Numéros publics, doublons | Confirmé | Moyen |

Le reset par `profile.phone` (V12/V1) est traité en L4.10.1 (autorisation distincte pour `passwordReset.js`) ; son ordre est donné §11.

## 4. Comportement cible de `checkClientPhone` (P0-A)

**Faits [F].** Aucun contrôle d'appelant ; limite `phone_check_<numéro>` 10/5 min (par numéro, donc contournable en changeant de numéro) ; renvoie `{exists, email}` ; deux usages applicatifs : inscription (`exists` → « numéro déjà associé à un compte ») et connexion (e-mail).

**Cible [R].**
1. **Plus aucun e-mail réel renvoyé ni existence révélée** par un appel de pré-authentification.
2. **Remplacer la connexion par téléphone** par une des options (décision D2-bis ci-dessous) : (a) *connexion serveur* : callable `clientPhoneLogin(phone, password)` qui vérifie le couple en interne (appel REST d'identité côté serveur ou résolution interne de l'e-mail) et retourne un **jeton personnalisé** ou une erreur uniforme — l'e-mail ne quitte jamais le serveur ; (b) *e-mail obligatoire* à la connexion (changement de produit) ; (c) *alias technique déterministe* pour tous les comptes (migration lourde). Recommandation : **(a)**.
3. **Inscription** : l'unicité du numéro passe côté **serveur à la création** (index d'unicité du registre ou, en attendant, vérification transactionnelle dans une fonction d'inscription) ; l'erreur « numéro déjà pris » devient une réponse **uniforme** (« impossible de créer ce compte, essayez de vous connecter ou de récupérer votre accès »), identique pour tous les motifs.
4. **Authentification** : exiger `request.auth` (session anonyme comprise) n'apporte presque rien ; la protection réelle = limites + App Check + réponses uniformes. App Check n'étant pas appliqué aujourd'hui [F, charte], son activation est une décision à part.
5. **Limites** : par appelant (`uid` de session), par appareil (identifiant d'installation/App Check lorsque disponible), par numéro **avec plafond doux** (délai croissant, pas de verrou dur susceptible de servir de déni de service contre un titulaire) ; compteur global anti-balayage (nombre de numéros distincts interrogés par appelant/heure).
6. **Énumération temporelle** : mêmes lectures et mêmes étapes pour numéro connu/inconnu ; réponse minutée sur un plancher de latence ; aucun champ variable dans la réponse.
7. **Audit/surveillance** : `security_events` à seuil (balayage de numéros, nombre d'échecs), compteurs agrégés sans numéros en clair (empreinte), alerte aux administrateurs de sécurité (la dépendance aux jetons FCM est une limite connue).

**Tests de non-divulgation** (aucun lancé) : réponse **octet-identique** pour numéro existant / inexistant / supprimé / en fermeture / admin ; absence d'e-mail dans toute réponse ou journal ; pas de différence de forme de l'erreur ; temps de réponse dans une tolérance ; limites par appelant et par numéro ; balayage de 100 numéros ⇒ blocage progressif ; ancien appelant (ancienne application) : comportement documenté. Type : unitaire (fonction injectée), émulateur, test de non-régression de la connexion.

## 5. Réclamation sécurisée des profils artisan (P0-B)

**Faits [F].** (i) La règle `service_providers` laisse tout utilisateur réel écrire `artisanUid == uid()` sur un profil sans `artisanUid` (`firestore.rules` 1326-1328). (ii) `artisanLogin` (callable, requiert une session — anonyme possible) accepte `phone` + `pin`, vérifie le PIN haché (`artisan_credentials`) ou, pour l'héritage, `artisanPin` en clair, puis **réécrit `artisanUid` avec l'uid de l'appelant s'il diffère** : un détenteur du PIN (ou un devineur) **reprend** le profil et l'éjecte. (iii) Limite : 10 essais/5 min par numéro (clé numéro seule) ⇒ un attaquant peut tenter ~120 PIN/h par numéro sans que sa session change la limite ; PIN à 4 chiffres : espace 10 000 ≈ 83 h d'essais continus (6 chiffres : infaisable) ; en revanche le même plafond permet à l'attaquant de **bloquer le titulaire légitime** (déni). (iv) Le compte artisan n'a pas de Firebase Auth : la session est anonyme.

**Conception [R].**
- **Preuve d'autorisation** : secret existant (PIN haché, comparaison à temps constant, jamais renvoyé) **plus** OTP du numéro **plus** (profils sans PIN/ambigus) validation administrative. Le numéro seul ne prouve rien (un numéro de profil est modifiable par le super et public).
- **Essais** : compteur persistant **par profil** (pas par numéro) avec verrou croissant, notification au titulaire (si canal), verrou levable par le support ; limite par appelant/appareil séparée.
- **Réclamation unique** : transaction sur le profil et un journal de réclamation (`version`, `claimId`, précondition `artisanUid` inchangé) ; un second claimant simultané obtient une erreur uniforme ; une réclamation sur un profil **déjà lié** exige la procédure de *reprise* (secret + OTP + délai + notification à l'ancien lien), jamais un simple écrasement.
- **Anciens profils/ambigus** (PIN en clair hérité, doublons de numéro, absence de PIN) : jamais de liaison automatique ; file de revue humaine ; migration paresseuse du PIN vers haché au premier login réussi.
- **Règle** : retirer la branche `artisanUid` du client (la fonction ne passe plus par elle [F, commentaire d'`index.js`]) — **après** vérification qu'aucune version d'application en circulation ne l'utilise ([NV] : aucun mécanisme de version).
- **Audit** : `logAudit`/`security_events` pour chaque réclamation, refus, reprise, verrou ; empreintes, jamais PIN ni numéro.
- **Sans Firebase Auth** : la liaison reste `artisanUid` (session anonyme) ; recommandation : session liée à un jeton personnalisé émis par la fonction, révocable.
- **PIN** : augmenter la longueur minimale ou ajouter une seconde preuve ; un PIN de 4 chiffres reste **insuffisant** même avec limites (verrou par profil requis).

## 6. Fonctions serveur pour les approbations vendeurs et livreurs (P1)

**Faits [F].** `admin_seller_requests_page.dart` : transaction client qui lit `sellers/{uid}`, lève `SellerAlreadyApprovedException` si présent, crée le vendeur depuis les données de `seller_requests/{uid}` (nom, téléphone, etc., saisis par le demandeur) et marque la demande `approved`. `driver_requests_page.dart` : lot client qui crée `livreurs/{uid}` (nom, téléphone, e-mail, identifiant, photos, `wallet:0`, `createdAt`) et **supprime la demande**; le garde d'existence est une vérification préalable (« déjà approuvé ») non transactionnelle dans l'extrait lu. Règles : `create: isAdmin()` pour `sellers` et `livreurs`.

**Conception [R]** (une fonction par rôle ou une fonction générique `approvePartnerRequest(kind, requestId)`) :
- **Entrée** : uniquement `{kind, requestId}` ; les champs du profil sont **relus côté serveur** depuis la demande, jamais fournis par le client administrateur.
- **Autorisation** : super-admin (ou permission dédiée), MFA et récence (garde commune), limitation de débit.
- **UID cible** : l'`uid` de la demande doit correspondre à un compte Auth existant, actif, non supprimé, non tombstoné ; l'uid ∉ `admins` ; aucun autre profil de rôle pour cet uid (politique un uid = un rôle).
- **Doublons** : refus si `sellers/{uid}`/`livreurs/{uid}` existe (réponse d'idempotence **sans écriture**), refus ou revue si le numéro est déjà associé à un autre uid.
- **Numéro** : le numéro de la demande reste **non vérifié** : le profil est créé avec un drapeau `phoneVerified:false` et un lien en attente de confirmation (aucun ancien numéro fiable par défaut).
- **Atomicité** : transaction unique : création du profil + marquage/suppression de la demande + trace d'événement ; échec ⇒ aucune écriture.
- **Audit** : `logAudit` avec l'admin, la demande, l'uid ; pas de PII.
- **Idempotence** : un second appel renvoie « déjà approuvé » sans effet.
- **Erreurs neutres** : mêmes messages pour demande introuvable / non autorisée.
- **Anciennes versions** : les anciennes versions de l'application d'administration (écriture client) échoueraient dès la fermeture de `create` ; prévoir période de recouvrement (règles inchangées) puis fermeture ; les administrateurs doivent être sur la version récente. Aucun mécanisme de version minimale n'existe [F] ⇒ **à créer ou à contourner par communication contrôlée** (les administrateurs sont peu nombreux).
- **Flutter/Web** : les deux écrans appellent la fonction (`httpsCallable`) au lieu d'écrire ; messages d'erreur mappés ; tests d'interface avec crochet de test (modèle existant : `manageSellerHook`).

## 7. Changement sécurisé de téléphone (P1)

Mécanisme serveur unique `changePhone` (pour les rôles identifiés : `clients`, `livreurs`, `sellers`, `boulangeries`, `fleet_owners`, `ekbine_agents`, `real_estate_agents` ; `service_providers`, `pharmacies`, `restaurant_owners` via procédure support).

- **Acteur** : session du titulaire (`request.auth.uid == uid`), avec **mot de passe récent vérifié côté serveur** (réauthentification Firebase récente : `auth_time` ≤ 5 min) — l'exigence Flutter seule n'est **pas** un contrôle [F].
- **Preuve** : OTP du **nouveau** numéro (jeton Phone Auth récent, usage unique) ; preuve de l'**ancien** numéro (OTP) si disponible ; sinon délai de sécurité (72 h) avec notification (FCM + notice) et possibilité d'annulation par le titulaire.
- **Recyclage** : un lien de plus de N mois exige re-confirmation avant d'autoriser un reset ; un numéro déjà lié à un autre compte ⇒ refus uniforme + anomalie.
- **Conflits** : index d'unicité ; remplacement du lien par transaction (`superseded`).
- **Audit** : événement serveur (empreinte seulement) ; `security_events` sur échec répété.
- **Limites** : par compte, par numéro, par appareil.
- **Profils sans Auth** : secret (mot de passe/PIN) + OTP ; jamais un OTP seul.
- **Comptes fermés/anonymisés/quarantaine** : refus uniforme (garde `assertTargetNotClosing`).
- **Pas de connexion par numéro** : le résultat est un lien de **récupération** uniquement.
- **Flutter** : `AuthService.updatePhone` remplacé par un appel fonction + flux OTP (écrans client et livreur) ; **anciennes versions** qui écrivent directement : tolérées jusqu'à la fermeture de la règle (décision de calendrier).

## 8. Matrice des règles Firestore à fermer progressivement (P2)

| Collection | Écritures actuelles (règle) | Acteurs | Écrans/fonctions dépendants | Remplacement serveur | Tests de règles | Fermeture sûre quand… |
|---|---|---|---|---|---|---|
| `sellers` | `create` super ; `update` super, sous-admin (6 champs), propriétaire (sauf champs protégés) | super, sous-admin, vendeur | `admin_seller_requests_page` (create) ; `manageSellerAccountCF` (déjà serveur) ; `seller_dashboard` (`photoUrl`) | `approvePartnerRequest` ; fonction `changePhone` | sous-admin refusé sur `phone` ; propriétaire sans `phone` ; `photoUrl` conservé | approbation migrée **et** déployée ; versions admin à jour |
| `clients` | création/`update` propriétaire (dont `phone`) ; `update` super | client, super | `client_auth_page`, `profil_client`, `updatePhone` | `changePhone` ; création sans `phone` libre | propriétaire ne change plus `phone` | `changePhone` + version minimale |
| `livreurs` | `create` super ; `update` propriétaire (dont `phone`), super | livreur, super | `driver_requests_page` (create), `driver_profil`, `fleetDriverCreation.js` | `approvePartnerRequest` ; `changePhone` | idem | approbation migrée ; `changePhone` |
| `boulangeries` | `create` super ; `update` super, propriétaire (sauf champs protégés, **`phone` non gardé**) | super, boulangerie | pages admin, `manageAdminPartnerAccount` | `manageAdminPartnerAccount` (déjà) ; `changePhone` | propriétaire sans `phone` | pages admin sur serveur |
| `fleet_owners` | création propriétaire (liste fermée avec `phone`) ; `update` propriétaire/super | patron de flotte, super | `fleet_register`, `fleet_dashboard` | `changePhone` | création inchangée (demande), mise à jour sans `phone` | `changePhone` |
| `ekbine_agents` | création propriétaire ; `update` propriétaire/super | agent, super | `ek_agent_register`, services Ekbine | `changePhone` ; **ne pas toucher aux numéros de dépôt/paiement** (champs distincts, fonction existante) | idem | `changePhone` |
| `real_estate_agents` | `create` super ; `update` propriétaire (dont `phone`) | agent, super | `realestate.js`, écrans | `changePhone` | idem | `changePhone` |
| `service_providers` | `create/update` super ; réclamation `artisanUid` par tout utilisateur réel ; `photos` par l'artisan lié | super, artisan | `artisanLogin`, `setArtisanPin`, `serviceProviderApplication.js`, `artisan_login` | réclamation sécurisée (§5) | refus de la réclamation directe | version de l'application sans claim direct [NV] |
| `pharmacies` | `write` super ; session liée : `fcmToken`, `logoUrl`, `isOnDuty` | super, session pharmacie | `admin_pharmacies_page` (écriture directe) | fonction d'administration pharmacies | super sans `phone` direct | page admin migrée |
| `restaurant_owners` | `write: isAdmin()` | super | `assignOwner` serveur, pages admin | `manageAdminPartnerAccount` | écriture directe refusée | tous les chemins serveur |

Principe : **ne fermer que les champs d'identité** (`phone`, création de profil avec uid arbitraire) ; laisser les écritures non identitaires (photo, GPS, jeton, disponibilité) intactes.

## 9. Conception du registre `account_phone_bindings` (hypothèse à valider)

Orientation conservée : accès **serveur seul** ; **HMAC-SHA256 à clé serveur** avec `keyId` ; index d'unicité transactionnel ; téléphone = **récupération seulement** ; aucun ancien numéro fiable ; migration à blanc → revue → confirmation ; aucun blocage automatique.

**Limites à évaluer.**
- **Rotation de clé** : conserver l'ancienne clé en lecture pendant la transition ; `keyId` par lien ; migration en tâche contrôlée par lots ; recalcul d'index (ancien `phoneHmac` → nouveau) en transaction ; **deux index** pendant la fenêtre ; échec partiel ⇒ lien reste lisible par l'ancienne clé ; compromission de la clé = énumération possible des numéros (espace faible) ⇒ procédure de rotation d'urgence et re-liaison.
- **Fuite du poivre** + export des index = reconstruction de l'annuaire de numéros ; stockage par secret géré ; accès limité.
- Unicité : aucune contrainte native ⇒ création `create`-only de l'index dans la transaction ; collisions concurrentes testées.
- Dépendance au support pour les cas sans lien ; coût de maintenance ; ne protège pas contre un super-admin ou un propriétaire GCP malveillant (limite incompressible).
- Séparation `profile.phone` / lien : risque de divergence perçue par les utilisateurs (UX) ⇒ message de rapprochement.

## 10. Les huit décisions à soumettre (repris de L4.10.3 §12)

| # | Question | Options | Avantages / risques | Recommandation | Si différée | Avis |
|---|---|---|---|---|---|---|
| D1 | Autoriser la modification de `passwordReset.js`, `index.js`, `manageSellerAccount.js`, des règles Firestore et des écrans Flutter d'approbation | par lot, ou tout | fichiers protégés ; risque de régression | autorisation **par mission** | rien ne se corrige | métier |
| D2 | `checkClientPhone` : rendre neutre/authentifié ; politique sur les numéros publics | (a) connexion serveur, (b) e-mail obligatoire, (c) alias technique ; numéros publics : retirer/migrer ou accepter | (a) sûr, développement plus long ; (b) rupture produit ; (c) migration lourde ; retrait des numéros : casse l'appel livreur/pharmacie côté client | (a) ; examiner les numéros publics séparément | fuite d'e-mails et énumération restent actives | **juridique/métier** (données personnelles, consentement, appel) |
| D3 | Réclamation `service_providers` et durcissement du PIN | verrou par profil + OTP + validation ; PIN plus long ; second facteur | complexité UX artisans | verrou par profil + OTP ; PIN ≥ 6 | prise de profils artisan possible | métier |
| D4 | Le titulaire peut-il changer son numéro seul ? | OTP nouveau seul ; nouveau + ancien/délai ; via support | sécurité vs friction | nouveau OTP + ancien/délai 72 h + notification | écriture directe sans OTP persiste | métier |
| D5 | Version minimale d'application et calendrier de fermeture des règles | version minimale forcée ; tolérance limitée ; campagne | blocage des utilisateurs d'anciennes versions | mécanisme de version minimale **avant** toute fermeture | impossible de fermer sans casser | métier |
| D6 | Registre seul vs registre + liaison Auth (téléphone moyen de connexion ?) | registre seul ; + fournisseur téléphone | recyclage de numéro = prise de compte si connexion SMS | **registre seul** | décision bloque le registre | sécurité/métier |
| D7 | Inventaire à blanc : périmètre, environnement, relecteurs | émulateur/export anonymisé ; préproduction ; production | confidentialité des données | export contrôlé avec revue par deux personnes | pas de backfill possible | **juridique** (RGPD/données ivoiriennes) |
| D8 | Poivre HMAC, état de Phone Auth, canal de notification | gestion de secret ; FCM + notice ; SMS | coût SMS, panne Phone Auth signalée | secret géré avec rotation ; FCM + notice | notification impossible | juridique pour SMS |

Les huit décisions ont été retrouvées dans L4.10.3 §12 (aucune inventée). Une neuvième, issue de ce plan (D2-bis : mécanisme de connexion par téléphone), est signalée comme sous-décision de D2.

## 11. Ordre d'exécution et dépendances (confirmé/corrigé par le code)

| Étape | Dépend de | Correction par rapport à l'hypothèse de travail |
|---|---|---|
| 0. Décisions D2, D3, D5 | — | ajouté |
| 1. `checkClientPhone` + nouvelle connexion par téléphone | D2, D5 | **plus lourd que prévu** : la connexion dépend de la fonction [F] ; indépendant des autres étapes |
| 2. Réclamation artisan | D3 | indépendant de 1 |
| 3. Fonctions d'approbation vendeurs/livreurs + écrans | D1 | doit précéder toute fermeture de `create` |
| 4. `changePhone` + écrans | D1, D4 | précède la fermeture de `phone` en écriture directe |
| 5. Mécanisme de version minimale | D5 | **ajouté** (absent du dépôt) |
| 6. Tests de compatibilité Flutter/Web | 1–5 | — |
| 7. Fermeture progressive des règles (champs d'identité) | 3, 4, 5, 6 | par collection, dans l'ordre §8 |
| 8. Exclusion `admins` et double rôle dans `passwordReset.js` (mode `log` → `enforce`) | D1 | **peut être faite tôt** et ne dépend ni de 3 ni de 4 |
| 9. Inventaire à blanc | D7 | indépendant du code |
| 10. Revue humaine | 9 | — |
| 11. Registre (création autorisée) | D6, D8, 9–10 | après la revue |
| 12. Migration contrôlée et vérification | 11 | confirmation à l'usage |

**Corrections indépendantes** réalisables sans les autres : étape 1 (une fois D2 tranchée), 2, 8, audit/HMAC de `manageSellerAccount.js`, uniformisation des messages d'erreur.

## 12. Tests et critères d'acceptation

| Type | Couverture | Critère de réussite mesurable |
|---|---|---|
| Unitaires | modules de garde (admin/double rôle), réponse uniforme, limites, verrou de PIN, usage unique d'OTP | 100 % des cas du §4–§7 ; mutations tuées (0 survivante) |
| Cloud Functions | `checkClientPhone`, `clientPhoneLogin`, réclamation artisan, approbations, `changePhone`, reset | réponses octet-identiques ; aucune PII dans réponses/journaux ; audit présent à chaque refus/succès |
| Règles Firestore | matrice §8 | chaque écriture directe d'identité refusée, chaque écriture non identitaire acceptée |
| Émulateur | Auth + Firestore `demo-*` : sessions après changement, unicité concurrente | 0 doublon sous 50 tentatives concurrentes ; comportement Firebase documenté |
| Flutter | écrans d'approbation, `updatePhone`, connexion par téléphone, récupération | tests d'interface verts avec crochets ; aucun appel Firestore direct résiduel pour les champs fermés |
| Web | candidatures et formulaires | inchangés ; aucune écriture profil |
| Concurrence | deux approbations, deux réclamations artisan, deux liens même numéro | un seul gagnant, l'autre refus uniforme |
| Idempotence | approbation, liaison, changement | second appel sans écriture supplémentaire |
| Non-régression financière | suites existantes (wallet, commissions, remboursements) | 0 régression (référence : dernière suite pure 2875 tests / 0 échec) |
| Comptes fermés/multiprofils | tombstone, quarantaine, admin+profil | refus uniforme, aucun effet de bord |
| Anciennes versions | écriture directe, appel `checkClientPhone` ancien contrat | comportement défini et message d'invitation à la mise à jour |

Exécution un seul lot à la fois sur les émulateurs ; aucun test lancé dans cette mission.

## 13. Retours arrière et sécurité opérationnelle

| Étape | Déclencheur | Restaurable | À ne jamais supprimer | Parcours maintenus | Suspension |
|---|---|---|---|---|---|
| 1 `checkClientPhone` | échec de connexion par téléphone > seuil | ancienne connexion via un **drapeau de configuration** sur la fonction nouvelle ; ne **rétablit pas** la fuite de l'e-mail sans décision écrite (mesure compensatoire : e-mail masqué + limite stricte) | journaux d'audit | connexion par e-mail | désactiver la fonction cliente nouvelle |
| 2 artisan | artisans légitimes verrouillés | levée de verrou par le support | journaux de réclamation, `artisan_credentials` | connexion historique pendant la transition (verrou par profil actif) | mode `log` |
| 3 approbations | échec d'approbation | ancien chemin d'écriture (règles inchangées) tant que `create` reste ouvert | demandes, profils créés | approbation manuelle par la console (procédure à deux) | fonction désactivée |
| 4 `changePhone` | échecs OTP/panne Phone Auth | écriture directe maintenue (règle non fermée) | liens, événements | changement via support | mode `log` |
| 7 règles | utilisateurs bloqués | redéployer la règle précédente (artefact conservé) | aucun document | support | — |
| 11–12 registre | anomalies | statut `revoked` ; retour à la preuve héritée **interdit** pour les rôles à risque sans décision écrite | liens, index, événements, journaux | support | mode `log` |

Un retour arrière **ne rétablit jamais** automatiquement une vulnérabilité critique : il bascule vers une mesure compensatoire (limites strictes, support manuel) et exige une décision explicite.

## 14. Risques résiduels

Anciennes versions sans version minimale ; panne/coût de Phone Auth ; numéros historiques potentiellement falsifiés ; recyclage de numéros ; numéros publics ; PIN artisan court ; fuite du poivre HMAC ; dépendance aux jetons FCM pour les alertes ; App Check non appliqué ; super-admins et propriétaires GCP gardent un pouvoir de contournement ; écrans web d'administration et `storage.rules` non audités **[NV]** ; production/préproduction non inspectées.

## 15. Autorisations nécessaires avant implémentation

Une autorisation **par mission** pour : (a) `checkClientPhone` + connexion par téléphone (D2) — fichiers `index.js` (protégé), `auth_service.dart`, `client_auth_page.dart` ; (b) réclamation artisan (D3) — `artisanAccounts.js`, règle `service_providers` ; (c) fonctions d'approbation + écrans (D1) ; (d) `changePhone` (D4) ; (e) mécanisme de version minimale (D5) ; (f) fermeture de règles par collection (déploiement distinct, jamais implicite) ; (g) `passwordReset.js` (protégé, hash `26975f60`) ; (h) inventaire (D7) ; (i) registre et secrets (D6, D8) ; (j) tout déploiement, commit ou push. Fichiers jamais touchés sans accord explicite : `feexpayPayments.js`, `orderRefunds.js` et les cinq fichiers sensibles.

## 16. Compte rendu final

- **Examiné** : rapports L4.10 → L4.10.3 (noms réels ci-dessus) et code cité en §2. **Huit décisions retrouvées** : D1–D8 (L4.10.3 §12) ; sous-décision D2-bis ajoutée et signalée comme telle.
- **Dépendances identifiées** : §11 ; **corrections indépendantes** : étapes 1, 2, 8, audit de `manageSellerAccount.js`.
- **Faits nouveaux** : la connexion par téléphone dépend de `checkClientPhone` ; `artisanLogin` réécrit `artisanUid` pour tout détenteur de numéro + PIN ; aucun mécanisme de version minimale ; l'approbation livreur est un lot client.
- **Critères d'acceptation** : §12. **Retours arrière** : §13.
- **État Git** : vérifié avant (HEAD `d65c8f0`, 35 modifiés, 167 non suivis, index vide, stash 0) ; état final dans le message de conversation.
- Aucun code, test, règle ni configuration modifié ; aucune donnée Firebase lue ou écrite ; aucun déploiement ; L4.11 non lancée ; `account_phone_bindings` non implémentée.

Arrêt : une autorisation explicite est requise pour chaque mission d'implémentation.
