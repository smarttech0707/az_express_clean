# Mission L4.10.1 — Conception de la correction du parcours `resetAccountPassword`

Conception en **lecture seule** : aucun code, test, règle, configuration ou secret modifié ; aucun accès Firebase ; aucune implémentation. Légende : **[F]** fait vérifié dans le dépôt ; **[H]** hypothèse (comportement Firebase ou production non vérifié) ; **[R]** recommandation. Les objectifs de sécurité du mandat sont traités comme **non implémentés**.

## 1. Analyse de la faille

**Cause racine [F].** `passwordReset.js` établit l'identité ainsi : (1) le jeton de l'appelant porte un `phone_number` vérifié ; (2) un document de profil contient un champ `phone` égal à ce numéro ; (3) l'**identifiant de ce document** est utilisé comme UID Firebase Auth et reçoit un nouveau mot de passe (`auth.updateUser(id, { password })`). Aucun lien d'origine serveur n'existe entre le numéro vérifié et le compte Auth cible : le seul lien est un champ de document **modifiable par d'autres acteurs que le titulaire** (cf. L4.10 : sous-admin « demandes_vendeurs » sur `sellers.phone` ; super-admin pouvant créer `sellers`/`boulangeries`/`restaurant_owners` avec un id et un `phone` arbitraires ; titulaire libre de poser n'importe quelle valeur dans son propre `phone`, absence d'unicité).

**Conséquences confirmées par lecture [F], exécution non faite.** Prise de contrôle du mot de passe d'un compte vendeur par un sous-admin ; prise de contrôle de n'importe quel compte Auth par un super-admin (y compris un autre super-admin) ; déni de réinitialisation par duplication de numéro ; aucune exclusion de `admins`, aucun audit, aucune notification, aucune révocation de session.

**Facteurs aggravants [F].** Les comptes partenaires créés par l'administration portent un e-mail technique (`<téléphone>@az-seller.ci`, `@az-restaurant.ci`…), non délivrable : la réinitialisation par e-mail leur est inutile, le SMS est donc leur seule voie de récupération, ce qui concentre la confiance sur le champ `phone`. Le client Flutter indique que Phone Auth présentait une panne côté projet (`INTERNAL (13) / Error code: 39`, commentaire de `forgot_password_page.dart`) : l'état actuel du parcours en production est **inconnu** [H].

## 2. Architecture actuelle

| Élément | Constat [F] |
|---|---|
| Client | `reset_password_page.dart` appelle `resetAccountPassword` avec `userType:'client'` codé en dur ; `generic_forgot_password_page.dart` pour les autres rôles ; `auth_service.resetPasswordViaSms` est désactivé (`UnsupportedError`). |
| Serveur | `passwordReset.js` (108 lignes), appelé via `onCall({maxInstances:2})` dans `index.js` ; l'ancienne version est commentée (inactive). Aucun `enforceAppCheck`. |
| Identité | token `phone_number` == numéro fourni ; recherche du document par `phone` (3 formes) ; unicité par id. |
| Garde de fermeture | `isDeleted` et `assertTargetNotClosing`. |
| Débit | 5 appels/h par uid appelant (`reset_password`), sans clé cible. |
| Effet | `auth.updateUser(id,{password})` ; PIN/hash pour artisan/pharmacie. |
| Absences | admin/double rôle, audit, notification, révocation, limite par cible, jeton à usage unique, binding Auth↔téléphone côté serveur, messages uniformes, tests d'admin. |

## 3. Architecture cible

Principes : **le champ `phone` d'un profil n'est jamais une preuve** ; l'identité du titulaire est établie par un lien **d'origine serveur ou Firebase Auth** (non modifiable par un administrateur ni par le titulaire sans nouvelle vérification) ; le refus est **uniforme** ; chaque réussite est tracée, notifiée, et ferme les sessions autant que Firebase le permet.

```
Appelant (token phone_number récent)
  → verrous d'abord : limites (appelant, numéro, uid cible), usage unique du jeton
  → résolution de la cible via le LIEN D'IDENTITÉ (pas via profile.phone)
  → refus uniforme si : cible absente / ambiguë / supprimée / en fermeture / dans admins / double rôle non exempté / lien incohérent avec le profil
  → transaction : consomme le jeton, pose le journal
  → auth.updateUser(password) → revokeRefreshTokens → audit → notification
  → réponse neutre
```

Modules proposés [R] (aucun créé ici) : `passwordResetIdentity.js` (résolution + refus, pur et testable), `passwordResetGuards.js` (exclusion admin / double rôle), journal serveur `password_reset_events` (écriture serveur seule, règle `write:false`, lecture super-admin).

## 4. Mécanisme d'identité recommandé

Comparaison des options (sans champ `phone` modifiable comme preuve suffisante) :

| Option | Principe | Force | Limites |
|---|---|---|---|
| A. Phone **lié au compte Auth** | Le compte cible a le fournisseur téléphone lié ; `auth.getUser(uid).phoneNumber == token.phone_number`, et idéalement `request.auth.uid == uid` (la connexion par SMS aboutit sur le compte lui-même) | **Maximale** : Firebase impose l'unicité du numéro entre comptes ; le lien nécessite la possession du numéro ; ni admin ni profil ne peuvent le falsifier sans OTP | Aujourd'hui la connexion téléphone crée un compte **distinct** quand aucun lien n'existe [H] ; exige une migration (lier le numéro à chaque compte existant) ; dépend de la disponibilité de Phone Auth (panne signalée) |
| B. Lien serveur `account_phone_bindings/{uid}` | Document écrit uniquement par fonction (règle `write:false`), contenant l'empreinte salée du numéro + collection + origine (`auth_link`, `admin_creation`, `verified_change`) ; la réinitialisation cherche par empreinte du numéro **vérifié** | Forte, indépendante du profil ; permet la détection de doublons ; pas de PII en clair | Les liens d'origine `admin_creation` héritent de la confiance accordée à l'administrateur créateur (contrôlé par la fonction de création, auditée) ; migration/backfill requis ; le sel/poivre doit être géré comme secret serveur existant |
| C. Numéro intégré à l'e-mail technique | Comparer la partie locale de l'e-mail Auth au numéro | Faible : l'e-mail peut être changé par le titulaire (`updateEmail`) ; n'existe que pour certains partenaires | À n'utiliser que comme **recoupement** |
| D. Second facteur supplémentaire | Question de sécurité, e-mail réel, TOTP | Utile pour les comptes à portefeuille ou à privilèges | Poids UX ; non disponible pour les e-mails techniques |
| E. Statu quo (`profile.phone`) | — | **Insuffisant** (faille) | — |

**Recommandation [R]** : cible finale = **A** (numéro lié à Auth) pour les rôles Firebase Auth, avec **B** comme mécanisme de transition et pour les rôles sans Auth (pharmacie, artisan, `pharmacy_owners`) ; **C** comme recoupement ; **D** pour les comptes à portefeuille élevé ou après changement récent de lien. Dans tous les cas : `auth_time` du jeton téléphone ≤ 5 minutes ; jeton à usage unique ; **refus en cas d'incohérence** entre lien, profil et Auth (le profil ne peut que *confirmer*, jamais *établir*).

**Backfill du lien B** : à partir des champs `phone` actuels — donc potentiellement déjà falsifiés. Le backfill est un **dry-run en lecture seule** produisant un rapport d'anomalies (doublons, recoupement e-mail technique, chevauchements `admins`, changements de numéro récents) soumis à revue humaine avant toute écriture ; aucune écriture automatique.

## 5. Exclusion des administrateurs

[R] Avant toute modification : lecture dans **la même transaction** de `admins/{uid}` pour l'uid cible (et pour `currentUid` des documents pharmacie) ; présence ⇒ refus, **sans exception possible** (même avec un profil `clients`, `livreurs`, `sellers`, `restaurant_owners`, `boulangeries`, `pharmacies`, `pharmacy_owners`, `fleet_owners`, `ekbine_agents`, `real_estate_agents`, `service_providers`). La lecture est indépendante du `userType` demandé et de la collection trouvée ; c'est un contrôle **sur l'uid**, pas sur le document. Le comportement vis-à-vis du demandeur est identique à « compte introuvable » ; la distinction n'existe que dans `security_events`/`password_reset_events`. [F] Le même schéma de refus existe déjà dans `adminPartnerAccounts.js` (cible présente dans `admins` ⇒ refus indistinguable d'un uid inconnu) et peut servir de modèle. Aucun profil n'est supprimé ni modifié. Le caractère *exclusif* d'`admins` doit aussi être appliqué à la création/promotion (L4.11).

## 6. Politique des doubles rôles

[R] **Un uid = un rôle métier principal.** Détection par lecture, dans la transaction, des collections de rôles de la liste (11 + `admins`). Résultat : seul le profil de la collection correspondant au `userType` peut exister ; tout autre ⇒ refus uniforme + événement de sécurité `password_reset_dual_role`. Exceptions : registre serveur `config/dual_role_exceptions` (`write:false`), entrées `{uid, collections[], reason, approvedBy×2, expiresAtMs}`, créées uniquement par fonction avec double approbation et audit, **jamais** pour `admins`, jamais auto-attribuées ni attribuées par le demandeur. Inventaire futur : rapport de lecture seule (script ou fonction) listant, par uid, les collections où il apparaît, les numéros dupliqués, et le croisement avec `admins`, produit hors production ou avec autorisation distincte ; **aucun compte à double rôle n'est présumé exister** (non vérifié). Les comptes légitimes à double rôle (le cas échéant) ne perdent pas leur accès normal par mot de passe ; seule la voie de réinitialisation SMS leur est fermée et ils passent par le support (action administrative existante, `manageAdminPartnerAccount`, auditée).

## 7. Protection contre les abus

| Protection | Conception [R] |
|---|---|
| Limites | Trois compteurs via `checkRateLimit` (clé = empreinte du numéro, pour éviter la PII) : par appelant (5/h existant), par **numéro vérifié** (3/h, 10/jour), par **uid cible** (3/h) ; plus un compteur d'échecs consécutifs avec verrou croissant. |
| Usage unique | Journal serveur `password_reset_events/{uid}` : l'`auth_time` consommé est enregistré en transaction ; une seconde tentative avec la même vérification est refusée. |
| Énumération | Une seule réponse pour tout échec (`failed-precondition`, message neutre « Réinitialisation impossible. Contactez le support si le problème persiste »), y compris type inconnu, plusieurs comptes, supprimé, admin, double rôle, lien incohérent ; mêmes étapes de lecture dans tous les chemins pour des temps comparables. Le numéro interrogé doit rester celui du jeton (déjà le cas). |
| Audit | `logAudit` + `logSecurityEvent` côté serveur (succès et refus avec motif interne), non modifiable par le client ; pas de numéro en clair (empreinte). |
| Notification du titulaire | Après réussite : notification FCM au `fcmToken` du profil (injection du service d'envoi existant) + trace dans une collection serveur (`user_notices/{uid}`) lisible par le titulaire ; pour les comptes sans jeton (clients anonymes, pharmacies), la notice est affichée à la prochaine connexion. SMS d'alerte = **décision distincte** (fournisseur et coût non établis). |
| Idempotence | Même mot de passe = même état final ; le journal d'usage unique évite la répétition d'effets (révocation, notification) pour une même vérification. |
| Fermeture/suppression | Conserver `isDeleted` et `assertTargetNotClosing` (id du document **et** uid du lien, plus `currentUid`), dans la même transaction que le refus admin/double rôle. |
| Doublons de numéro | Lien B garantit une empreinte unique par numéro ; plusieurs candidats ⇒ refus uniforme + événement d'anomalie (au lieu du message actuel qui révèle des doublons). |
| Profil falsifié | Si `profile.phone` ≠ numéro du lien ⇒ refus + événement d'anomalie (signal de manipulation). |
| App Check | Hors périmètre ici ; recommandé en complément si activé globalement (décision de rollout séparée). |

## 8. Gestion des sessions

**Garanties Firebase connues (documentation générale) [H, à vérifier sur l'émulateur Auth]** :
- `auth.revokeRefreshTokens(uid)` invalide les **jetons de rafraîchissement** ; les **jetons ID déjà émis restent valides jusqu'à leur expiration (≈ 1 h)**. Les règles Firestore/Storage **ne vérifient pas la révocation** ; seule `verifyIdToken(token, true)` côté serveur détecte la révocation.
- L'effet exact de `auth.updateUser(uid,{password})` sur les jetons de rafraîchissement n'est **pas établi dans le dépôt** : ne pas s'y fier ; appeler explicitement `revokeRefreshTokens` après la mise à jour.
- Fenêtre résiduelle inévitable : un attaquant déjà connecté garde un jeton ID valide ≤ 1 h. Mitigations réalisables : `checkRevoked` sur les fonctions critiques (coût), comparaison `auth_time` < `tokensValidAfterTime`, notification au titulaire, désactivation temporaire possible (`disabled:true`) sur incident via le flux de fermeture existant.
- Pour les rôles sans Auth (pharmacie, artisan), invalider les sessions applicatives dépendantes du hachage (la reconnexion se fait par fonction ; vérifier que les anciens identifiants ne sont plus acceptés).

## 9. Matrice de tests (à préparer, non écrits)

| # | Test | Attendu |
|---|---|---|
| 1 | UID présent dans `admins`, profil de n'importe quelle collection | refus uniforme, aucun `updateUser`, événement de sécurité |
| 2 | Admin + profil `clients` | refus |
| 3 | Admin + profil `sellers` | refus |
| 4 | Admin + chacun des 11 autres profils | refus (boucle paramétrée) |
| 5 | Numéro de profil modifié par un tiers (simulé) | refus (lien ≠ profil) |
| 6 | Profil créé par un super avec l'uid d'un tiers et son numéro | refus (aucun lien pour ce numéro) |
| 7 | Numéro non vérifié / absent du jeton | refus |
| 8 | Numéro vérifié ≠ numéro du lien | refus |
| 9 | Plusieurs profils pour un uid sans exception | refus ; avec exception valide : accepté |
| 10 | Numéros dupliqués | refus uniforme + anomalie |
| 11 | Compte supprimé / en fermeture / tombstone | refus uniforme |
| 12 | Limites : appelant, numéro, uid cible, verrou croissant | refus après seuil, fenêtre glissante |
| 13 | Usage unique du jeton (même `auth_time` rejoué) | second appel refusé |
| 14 | Messages et erreurs | indiscernables entre échecs ; mêmes champs ; temps comparables |
| 15 | Audit et événements | écrits serveur ; sans données sensibles ; refus journalisés |
| 16 | Notification | émise après succès, jamais après échec ; échec d'envoi n'annule pas la réinitialisation mais est tracé |
| 17 | Révocation | `revokeRefreshTokens` appelé ; test d'intégration sur **émulateur Auth** pour mesurer l'effet réel sur refresh/ID tokens |
| 18 | Parcours normal (client, fleet, seller, restaurant, boulangerie, pharmacie, artisan) | succès, mot de passe changé, journal, notification |
| 19 | Règles Firestore : `account_phone_bindings`, `password_reset_events`, `dual_role_exceptions` | `write:false` pour tout client, super-admin inclus |
| 20 | Concurrence : deux resets simultanés, reset pendant fermeture, reset pendant promotion admin | un seul gagne, aucun effet sur admin |
| 21 | Mutations sur chaque garde ; mutation de l'ordre « verrous avant effet » | tuées |

Tous ces tests s'exécutent sur faux Firestore / émulateur `demo-*`; aucun sur production.

## 10. Plan de migration

1. **Phase 0 — décisions** (§12) et inventaire en lecture seule (script/fonction, hors production tant que non autorisé).
2. **Phase 1 — correctifs sans schéma** (module séparé, autorisation pour `passwordReset.js`/`index.js` requise) : exclusion `admins`, refus des doubles rôles, messages uniformes, limites par cible, journal/audit, notification, `revokeRefreshTokens`. Mode `PASSWORD_RESET_GUARD_MODE=off|log|enforce` (liste fermée, valeur invalide ⇒ erreur de configuration, jamais traité silencieusement comme `log` — leçon de `ADMIN_MFA_MODE`).
3. **Phase 2 — règles** (autorisation séparée) : retirer `phone` des champs écrits par le sous-admin « demandes_vendeurs » ou le conditionner à une fonction auditée avec gel du reset ; fermer la création directe de `sellers`/`boulangeries`/`restaurant_owners` par un super au profit de la fonction serveur.
4. **Phase 3 — liens** : backfill en dry-run, revue humaine des anomalies, écriture des liens par fonction journalisée, mode `log` puis `enforce` de la résolution par lien ; liaison progressive du fournisseur téléphone (option A) pour les rôles Auth.
5. **Phase 4 — extinction** du chemin `profile.phone` comme preuve ; surveillance ; retrait de la voie legacy.
6. **Retour arrière** : passer le mode à `log` ; aucun compte supprimé ou désactivé automatiquement. Récupération d'accès si un utilisateur légitime est refusé : support via l'action administrative existante.
7. Pas de perte d'accès : la voie support reste disponible durant toutes les phases ; deux super-admins joignables avant `enforce`.

## 11. Risques et dépendances

- **Risques résiduels** : jeton ID valable ≤ 1 h après révocation ; recyclage de numéros par l'opérateur (le lien Auth/binding doit être réinitialisé par une vérification de changement) ; panne ou coût de Phone Auth/SMS ; backfill dépendant de données déjà potentiellement falsifiées ; blocage de comptes légitimes à double rôle ; propriétaires GCP (limite incompressible).
- **Dépendances** : L4.11 (gestion des administrateurs, exclusivité de `admins`, fonctions de création) ; règles `sellers`/créations par super ; mission MFA (`ADMIN_MFA_MODE`) ; autorisations pour les fichiers protégés `passwordReset.js` (26975f60), `index.js` (a9ba2c0d), `adminPartnerAccounts.js` (1a5cde55) ; inventaire des comptes ; choix du canal de notification.
- **Fichiers à ne pas toucher sans autorisation** : `feexpayPayments.js`, `orderRefunds.js` et les cinq fichiers sensibles.

## 12. Décisions nécessitant une autorisation distincte

1. Modifier `passwordReset.js` et `index.js` (fichiers protégés) ; créer les modules proposés.
2. Choix du mécanisme d'identité : A (lien Auth) seul, B (lien serveur) en transition, ou mixte ; durée de la transition.
3. Création de collections serveur (`account_phone_bindings`, `password_reset_events`, `user_notices`, `config/dual_role_exceptions`) et de leurs règles `write:false`.
4. Modification des règles `sellers` (champ `phone` du sous-admin) et des créations directes par super ; calendrier de déploiement (aucun déploiement sans demande explicite).
5. Politique « un uid = un rôle » et liste d'exceptions ; traitement des comptes à double rôle légitimes.
6. Canal de notification du titulaire (FCM + notice in-app ; SMS ?) et durée du gel après changement de lien.
7. Inventaire réel des comptes (lecture sur préproduction/production) et exécution du backfill.
8. Vérification du comportement Firebase (émulateur Auth, puis préproduction) pour `updateUser`/`revokeRefreshTokens`/claims téléphone.
9. Activation d'App Check et d'`ADMIN_MFA_MODE=enforce` (missions séparées).

## 13. Compte rendu final

- **Fichiers consultés** : `functions/passwordReset.js` (relu), `lib/screens/auth/reset_password_page.dart` (flux client), `forgot_password_page.dart` (commentaires), `lib/services/auth_service.dart` (reset SMS désactivé, conventions d'e-mails techniques), `functions/adminPartnerAccounts.js` (conventions d'e-mail technique, refus d'admin), rapports L4.9, L4.9.1, L4.10.
- **Solutions étudiées** : A–E (§4), exclusion d'`admins` (§5), politique double rôle (§6), protections (§7), sessions (§8).
- **Limites de Firebase identifiées** : jeton ID non révocable avant expiration ; règles sans contrôle de révocation ; effet de `updateUser(password)` sur les refresh tokens non établi ; la connexion téléphone crée un compte séparé sans lien préalable ; recyclage de numéros ; dépendance à la disponibilité de Phone Auth [toutes **[H]** sauf mention du commentaire client].
- **Risques résiduels** : §11. **Décisions** : §12.
- **Disque** : aucun nettoyage effectué ; `C:` utilisé uniquement pour les outils de la session, rapport écrit sur `D:`.
- **État Git final** : HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 165 non suivis (164 + ce rapport) — confirmé par la vérification faite après écriture.
- Aucune modification de code, test, règle ou configuration ; aucun secret ; aucun accès Firebase ; aucun build ; L4.11 et le registre des créances non commencés.

Arrêt : en attente d'une nouvelle autorisation explicite.
