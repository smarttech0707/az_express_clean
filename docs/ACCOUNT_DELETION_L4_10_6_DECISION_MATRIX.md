# Mission L4.10.6 — Dossier d'arbitrage des questions ouvertes et validation du plan M0–M10

Mission **en lecture seule** : seul ce rapport est créé. Aucun fichier applicatif, test, règle, configuration ou secret modifié ; aucun accès Firebase ; aucun test, build ou déploiement. Référence principale : `docs/ACCOUNT_DELETION_L4_10_5_TECHNICAL_PLAN.md` (L4.10.5), qui corrige L4.10.4 : **`MinVersionService` et `config/app_versions` existent**. Légende : **[F]** fait vérifié par lecture ; **[R]** recommandation ; **[D]** déduction ; **[NV]** non vérifiable ici.

## 1. Résumé exécutif

- Le rapport L4.10.5 contient bien **12 questions ouvertes** (§15) et les missions **M0 à M10** (§10) ; rien n'est inventé ici.
- **Contradiction technique réelle découverte** (sur une décision prise) : D2 inscription (« réponse uniforme si le numéro est déjà utilisé ») est **incompatible avec une connexion automatique immédiate** sans preuve de possession du numéro. Ce n'est pas un revote : la décision est conservée, mais sa **mise en œuvre** impose un choix (Q4). Voir §4.
- **Complément D5 vérifié** : `scripts/build_mobile.py` construit avec `--dart-define-from-file=<defines>` (`build_mobile.py:55-57`) et valide un contrat strict de variables Firebase (`:40-49`) ; aucune occurrence de `APP_BUILD_NUMBER` dans le dépôt hors documentation (`DELIVERY_TRANSFER.md:38,44`, `REAL_DEVICE_TEST_CHECKLIST.md:10`) et `lib/services/min_version_service.dart:6`. Le contenu du fichier `defines` réel est **[NV]** (non versionné, non lu). La mission M2 doit donc intégrer le numéro de build au script **et à ses tests** (`scripts/test_build_mobile.py`).
- Ordre recommandé : M0 (décisions) → M1 (faisabilité locale) et M2 (version minimale) en parallèle → M3/M4/M5 → M6 (documentaire, à tout moment) → M7 → M8 (30 jours) → M9 → M10. **Aucune fermeture de règle avant la fin de M8.**
- Rien dans ce dossier n'autorise une implémentation.

## 2. Décisions déjà prises (acquises, non soumises à revote)

| Réf. | Décision | Point d'attention |
|---|---|---|
| D2-bis | Option A : connexion téléphone + mot de passe vérifiée côté serveur, e-mail jamais exposé | faisabilité Auth à valider en M1 |
| D2 numéros | Étude juridique/métier préalable ; aucune suppression immédiate | M6 documentaire |
| D2 inscription | Réponse uniforme si numéro déjà utilisé | **contradiction d'implémentation → Q4** |
| D3 | OTP, PIN ≥ 6 chiffres, verrou progressif par profil | Phone Auth [NV] |
| Récupération artisan | Support + administrateur, contrôlée et tracée | paramètres → Q5, Q6 |
| D5 | Améliorer le mécanisme existant | voir §10 |
| Transition | 30 jours à partir de T0 (version complète disponible sur tous les canaux) | canaux → Q9 |
| App Check | Étude séparée | hors périmètre |

## 3. Les 12 questions ouvertes (formulation exacte de L4.10.5 §15)

1. « Accepter la création de `clientPhoneLogin` avec **clé API Web fournie en configuration** et la nécessité d'un rôle de signature pour les jetons personnalisés (validation de faisabilité d'abord) ? »
2. « Pendant la transition, conserver le contrat actuel de `checkClientPhone` (fuite d'e-mail) ou imposer une mesure compensatoire plus stricte (au risque de casser les anciennes versions) ? »
3. « Mesure compensatoire minimale acceptable pendant 30 jours (limites par appelant et par numéro) ? »
4. « Inscription : OTP avant toute information, ou réponse uniforme sans connexion automatique ? »
5. « Artisans : valeurs du verrou progressif, durée de la fenêtre de contestation (72 h ?), double validation pour quels cas ? »
6. « Artisans : qui est le "support" (personnes, permission `support`) et qui approuve (permission `services`, super) ? Vérification en personne obligatoire pour quels cas ? »
7. « PIN ≥ 6 : changement forcé au prochain login pour tous les artisans ? »
8. « Utilisateurs sur appareils non mis à jour : maintien d'un mode lecture ou blocage total ? Appareils < Android 7.0 / iOS 13 ? »
9. « Origine de T0 : quels canaux doivent être à jour (Play, App Store, APK direct) et quel suivi de part de version est accepté ? »
10. « Dépendances nouvelles autorisées (`package_info_plus`, `in_app_update`) ou conservation du numéro de build injecté ? »
11. « Numéros publics : qui mène l'étude juridique, et quel arbitrage entre appel direct et alternatives (§5) ? »
12. « Statut réel de Phone Auth en production et de l'App Store (iOS) à fournir par le propriétaire. »

## 4. Analyse de chaque question

Pour chaque question : **Problème** · **Options du rapport** · **Avantages/risques** · **Conséquences** · **Recommandation [R]** · **Décision attendue** · **Vérifications préalables**. Les options listées sont celles de L4.10.5 ; ce qui est ajouté est marqué [D] ou [R].

### Q1 — Clé API Web et jetons personnalisés
- **Problème** : le SDK Admin ne vérifie pas de mot de passe [H] ; il n'existe aujourd'hui dans `functions/` ni appel REST d'identité ni `createCustomToken` [F, L4.10.5 §2].
- **Options (rapport §3.2)** : appel REST « sign in with password » avec la clé API Web + `createCustomToken` (rôle de signature requis). Alternatives écartées par le rapport : renvoyer l'e-mail ; renvoyer des jetons d'ID/rafraîchissement.
- **Avantages** : comptes et uid préservés, e-mail jamais exposé. **Risques** : jeton personnalisé non validé sur ce projet ; fournisseur de session `custom` pouvant casser `reauthenticateEmail` (`auth_service.dart` `updatePhone`) [H] ; revendications à reprendre [H] ; la clé Web est un identifiant public mais doit être fournie comme configuration (aucun secret lu).
- **Conséquences** : M3 est bloquée tant que M1 n'a pas tranché.
- **[R]** Accepter le principe **sous condition** de la validation M1 locale ; si M1 échoue, revenir au propriétaire avec la contradiction.
- **Décision attendue** : « oui sous réserve de M1 » ou non. **Vérifications** : M1 (émulateur Auth `demo-*`).

### Q2 — Contrat de `checkClientPhone` pendant la transition
- **Problème** : la fonction (`index.js:1712-1727`) renvoie l'e-mail ; les anciennes versions en dépendent (`auth_service.dart:25-43`).
- **Options** : (a) conserver le contrat actuel (fuite persistante 30 jours) ; (b) mesure plus stricte, au risque de casser les anciennes versions.
- **Avantages/risques** : (a) aucune casse, fuite maintenue ; (b) ferme la fuite plus tôt, casse la connexion par téléphone des versions anciennes (nombre inconnu [NV]).
- **Conséquences** : la fuite d'e-mail est la faille P0 de L4.10.4 ; la maintenir 30 jours est un risque accepté explicitement.
- **[R]** (a) combinée à la mesure de Q3 ; c'est cohérent avec « ne pas casser les comptes existants ».
- **Décision attendue** : choix (a) ou (b) et acceptation écrite du risque résiduel. **Vérifications** : aucune supplémentaire ; part des anciennes versions [NV] (mesurable seulement après M2).

### Q3 — Mesure compensatoire minimale
- **Problème** : limiter l'énumération pendant la transition sans changer la forme de la réponse.
- **Option du rapport** : limites strictes par appelant et par numéro (`checkRateLimit`). Valeurs non chiffrées dans le rapport.
- **Risque** [D] : une limite par appelant est contournable avec des sessions anonymes multiples ; une limite par numéro seule peut gêner le titulaire.
- **[R]** Chiffrer les seuils en M3 ; ne jamais verrouiller durement un numéro. L'efficacité réelle reste partielle (App Check, étude séparée).
- **Décision attendue** : valider le principe ; seuils fixés en M3. **Vérifications** : test unitaire des compteurs.

### Q4 — Inscription : OTP ou réponse uniforme sans connexion automatique
- **Contradiction technique** : si l'inscription réussie renvoie une session, un numéro déjà pris ne peut pas produire la même réponse sans prouver la possession du numéro (L4.10.5 §4).
- **Option (a) OTP avant toute information** : divulgation « déjà utilisé » limitée au détenteur du numéro. Avantage : sécurité et expérience conservée ; risque : dépend de Phone Auth (panne `INTERNAL (13) / 39` signalée [NV]), coût SMS, **tension avec D6 si le téléphone devient moyen de connexion** (à éviter, voir Q-M1).
- **Option (b) réponse identique sans connexion automatique** : uniforme et sans dépendance SMS ; dégrade l'expérience (une étape de connexion de plus ; nouveau client qui ne comprend pas).
- **[R]** (b) comme défaut si Phone Auth n'est pas fiable (Q12) ; (a) si Phone Auth est confirmé stable.
- **Décision attendue** : (a) ou (b). **Vérification préalable** : Q12.

### Q5 — Paramètres du verrou, contestation, double validation
- **Problème** : rapport donne des **exemples** (5 échecs ⇒ 1 min, 7 ⇒ 30 min, 10 ⇒ 24 h ; fenêtre 72 h ; double validation pour profil lié à un autre appareil, numéro changé récemment, profil vérifié/à fort volume, contestation en cours, hors heures).
- **Risque** : trop strict ⇒ artisans bloqués ; trop lâche ⇒ force brute (PIN 6 chiffres = 10⁶ combinaisons, [D] le verrou par profil rend l'attaque en ligne irréalisable).
- **[R]** Adopter les valeurs d'exemple comme point de départ, ajustables par configuration validée.
- **Décision attendue** : valeurs, fenêtre, liste des cas à double validation.

### Q6 — Rôles support/admin et vérification en personne
- **Problème** : définir qui exécute la procédure (§7 de L4.10.5 : le support ouvre, un administrateur `services`/super approuve, exécuteur = fonction serveur).
- **Risque** : sur un petit effectif, peu de personnes ⇒ séparation des tâches difficile [D].
- **[R]** Vérification en personne à Abengourou pour les cas sensibles (liste en Q5) ; justificatifs non conservés.
- **Décision attendue** : noms/rôles, permission requise, cas exigeant la présence physique.

### Q7 — PIN ≥ 6 : changement forcé
- **Problème** : les PIN existants de 4–5 chiffres ne sont pas détectables (seul le haché est stocké) ; le serveur ne les connaît qu'à la saisie d'un login réussi (L4.10.5 §6.2).
- **Options** : changement exigé à la prochaine connexion réussie (après OTP) pour tous ; aucune migration automatique.
- **Risque** : artisans bloqués sans OTP ; dépendance Phone Auth.
- **[R]** Oui, au prochain login réussi, avec délai de grâce borné.
- **Décision attendue** : oui/non et durée de grâce.

### Q8 — Appareils non mis à jour
- **Problème** : utilisateurs sous Android < 7.0 (API 24) ou iOS < 13 ne peuvent pas installer la nouvelle version (`DISTRIBUTION_ANDROID.md`, `project.pbxproj`).
- **Options** : mode lecture ou blocage total.
- **[D]** Un mode lecture suppose de distinguer lecture/écriture dans l'application (travail supplémentaire) ; le blocage total est simple mais exclut ces utilisateurs.
- **Décision attendue** : choix + éventuelle exception. **Vérification** : part de ces appareils [NV].

### Q9 — T0 et canaux
- **Problème** : trois canaux Android/iOS (Play, APK direct `/telecharger`, App Store) ; le décompte ne commence qu'à disponibilité sur tous.
- **Risque** : un canal en retard repousse T0 indéfiniment ; suivi de version inexistant aujourd'hui [F].
- **[R]** Lister les canaux réellement utilisés (Q12) ; suivi anonymisé `{rôle, plateforme, build}`.
- **Décision attendue** : liste des canaux obligatoires et suivi accepté.

### Q10 — Dépendances nouvelles
- **Problème** : `pubspec.yaml` n'a ni `package_info_plus` ni `in_app_update` [F].
- **Options** : ajouter ces paquets (version lue du binaire, mise à jour Play dans l'application) ou conserver le numéro injecté.
- **Risque** : paquets = surface de maintenance ; le numéro injecté est faillible tant que le script de build ne le force pas.
- **[R]** Conserver le numéro injecté **rendu obligatoire dans le build** ; `in_app_update` différé (Play uniquement) ; `package_info_plus` possible comme contrôle croisé.
- **Décision attendue** : liste de dépendances autorisées.

### Q11 — Numéros publics
- **Problème** : numéros lisibles par tout utilisateur connecté, anonymes inclus, dans plusieurs collections ; appels `tel:` directs (L4.10.5 §5).
- **Options (rapport §5, non retenues)** : exposition aux participants d'une commande active ; numéros d'établissement vs personnels ; appel/chat dans l'application ou numéro intermédiaire ; statu quo documenté avec consentement.
- **Conséquence** : toute restriction casse les boutons d'appel tant qu'une alternative n'existe pas.
- **[R]** M6 purement documentaire, mené par un juriste ou le conseil du propriétaire ; aucune décision technique avant ses conclusions.
- **Décision attendue** : désigner qui mène l'étude et son délai.

### Q12 — Statut réel de Phone Auth et App Store
- **Problème** : conditionne Q4, Q7 et l'OTP artisan (D3). **[NV]** depuis le dépôt (panne signalée dans `forgot_password_page.dart`).
- **Décision attendue** : information factuelle du propriétaire (fonctionne ? quotas/coûts SMS ? application publiée sur l'App Store ? versions en circulation).

## 5. Décisions encore nécessaires

| Q | Décision | Bloque | Priorité |
|---|---|---|---|
| Q12 | Statut Phone Auth / App Store (information) | Q4, Q7, M5 | **1** |
| Q9 | Canaux requis pour T0 | M2, M8 | **1** |
| Q10 | Dépendances | M2 | 2 |
| Q1 | Principe clé Web / jeton (sous réserve M1) | M1, M3 | 2 |
| Q2, Q3 | Contrat de transition et mesure | M3 | 2 |
| Q4 | Inscription (a)/(b) | M4 | 3 |
| Q5, Q6, Q7 | Paramètres et rôles artisans | M5 | 3 |
| Q8 | Appareils anciens | M2, M8 | 3 |
| Q11 | Responsable de l'étude juridique | M6 | 3 |

## 6. Analyse détaillée M0–M10

Tous les chiffrages de fichiers sont ceux de L4.10.5 §11 ; **« sans Firebase »** = réalisable localement avec émulateurs/doublures.

| Mission | Objectif | Périmètre | Fichiers | Dépend de | Risques principaux | Critères d'acceptation | Vérifications | Autorisation distincte | Sans Firebase |
|---|---|---|---|---|---|---|---|---|---|
| **M0** | Arbitrage des Q1–Q12 | Décisions écrites | aucun | — | décisions implicites | 12 réponses consignées | — | non (décision) | oui |
| **M1** | Faisabilité technique | jeton personnalisé, REST mot de passe, session, effets sur `reauthenticateEmail`/revendications, OTP via instance secondaire, source d'installation | prototypes jetables hors dépôt applicatif | M0 (Q1) | résultats limités à l'émulateur ; REST réel non testable sans projet | rapport de faisabilité par point : vérifié local / non vérifiable | émulateur Auth `demo-*`, Node 22 | **oui** (création de code de test, exécution de tests) | **oui** (émulateur) ; le REST réel et les rôles IAM restent [NV] |
| **M2** | Version minimale complète | `APP_BUILD_NUMBER` obligatoire au build, bouton de mise à jour, rôles non couverts, par plateforme, `enforceAfter`, suivi | `scripts/build_mobile.py`, `scripts/test_build_mobile.py`, `min_version_service.dart`, `min_version_dialog.dart`, tableaux de bord des rôles, fonction de rapport (nouvelle) | M0 (Q8–Q10) | blocage involontaire d'utilisateurs ; build à 0 ; fail-open | build sans numéro ⇒ échec du script ; dialogue obligatoire avec bouton ; tests d'évaluation (matrice build × config) | tests Dart/Python locaux | **oui** (modifications Flutter/scripts) ; `config/app_versions` = **autorisation séparée** | **oui** pour le code ; la donnée `config/app_versions` exige Firebase |
| **M3** | `clientPhoneLogin` + compatibilité `checkClientPhone` | callable, écran, mode de compatibilité (valeurs fermées) | `functions/index.js` (**protégé**), nouveau `functions/clientAuth.js`, `auth_service.dart`, `client_auth_page.dart`, parcours web [NV] | M1, Q1–Q3 | régression de connexion ; fuite persistante ; latence ; DoS du titulaire | cf. L4.10.5 §13 (0 e-mail, réponses identiques, 100 % comptes de test) | émulateurs, tests unitaires | **oui** + accord explicite pour `index.js` | oui (émulateur) |
| **M4** | `registerClient` | unicité serveur, réservation, compensation, réponse uniforme | idem M3 + règle `clients` (fermeture plus tard) | M1, Q4 | comptes orphelins ; expérience dégradée | 50 inscriptions concurrentes ⇒ 1 compte, 0 orphelin | émulateurs | **oui** | oui |
| **M5** | Artisans | réclamation, PIN ≥ 6, verrou, OTP, récupération support/admin | `artisanAccounts.js`, `artisanCredentials.js`, `artisanPhotos.js`, `passwordReset.js` (**protégé**), `artisan_login.dart`, `artisan_dashboard.dart`, `artisan_account_service.dart`, `admin_services_page.dart` | M1, Q5–Q7, Q12 | blocage d'artisans ; profils hérités ; dépendance Phone Auth | PIN < 6 refusé ; 5e échec ⇒ verrou ; 2 réclamations parallèles ⇒ 1 gagnant ; reprise tracée | émulateurs, fakeDb | **oui** + accord pour `passwordReset.js` | oui (OTP réel [NV]) |
| **M6** | Étude juridique numéros publics | rapport documentaire | docs | Q11 | décision précipitée | avis juridique consigné | — | non (documentaire, mais accord sur l'auteur) | oui |
| **M7** | Approbations vendeurs/livreurs et changement de téléphone (L4.10.4) | fonctions serveur pour remplacer les créations client | `admin_seller_requests_page.dart`, `driver_requests_page.dart`, `manageSellerAccount.js`, etc. | M2 | casser les flux d'inscription partenaires | flux partenaires fonctionnels avec nouvelles fonctions | émulateurs | **oui** | oui |
| **M8** | Transition de 30 jours | opérationnel : communication, suivi, alertes | `config/app_versions` (donnée), publication | M2–M5 déployés | T0 retardé ; utilisateurs hors connexion | calendrier L4.10.5 §9 respecté, parts résiduelles mesurées | tableau de bord de versions | **oui** (déploiement et écriture de configuration, séparés) | **non** |
| **M9** | Fermetures de règles, collection par collection | `firestore.rules` | `firestore.rules`, `rules-tests/` | M8, M7 | `permission-denied` silencieux chez les anciens clients ; indisponibilité | matrice de fermeture verte ; dry-run validé | `npm run test:rules` (Java), dry-run | **oui**, déploiement distinct par collection | tests locaux oui ; déploiement non |
| **M10** | Inventaire à blanc → revue → registre des liaisons | lecture de données | scripts de dry-run, `account_phone_bindings` (hypothèse) | décisions D6–D8 | HMAC/clé ; données réelles | rapport de revue humaine | — | **oui** (accès aux données) | **non** |
| (App Check) | Étude séparée | — | — | — | — | — | — | mission propre | — |

*Remarque* : M3 et M4 modifient les mêmes fichiers (conflit de fusion possible) ; ne pas les fusionner, mais les séquencer.

## 7. Dépendances

```
M0 ──► M1 ──► M3 ──► M4
 │      └────► M5 (aussi Q12)
 ├────► M2 ─────────┐
 └────► M6 (indép.) │
M7 ◄── M2           ▼
M3,M4,M5,M7 déployés ──► M8 (30 j) ──► M9 (règles) ──► M10
```

| Mission | Prérequis durs | Prérequis recommandés |
|---|---|---|
| M1 | Q1 | — |
| M2 | Q8, Q9, Q10 | — |
| M3 | M1 | M2 (pour mesurer les anciennes versions) |
| M4 | M1, Q4 | M3 |
| M5 | M1, Q5–Q7, Q12 | M2 |
| M7 | M2 | M5 |
| M8 | M2, M3, M4, M5 en production | M7 |
| M9 | M8, M7 | M6 |
| M10 | D6–D8 | M9 |

## 8. Ordre recommandé

1. **M0** (réponses, priorité Q12 → Q9 → Q10 → Q1).
2. **M2** en premier chantier d'implémentation : il n'a pas besoin de la faisabilité Auth, il conditionne tout T0, et il est sans risque financier. **M1** en parallèle (aucun effet sur le dépôt applicatif).
3. **M3**, puis **M4** (mêmes fichiers).
4. **M5** (après M1 et Q12).
5. **M6** à tout moment.
6. **M7**.
7. **M8** (30 jours) : le premier décompte ne démarre qu'avec toutes les versions disponibles.
8. **M9**, une collection par déploiement ; **M10** ensuite.

*Raison du choix de M2 d'abord [R/D]* : la version minimale a une valeur de sécurité nulle seule, mais c'est la **seule** manière de préparer des utilisateurs avant fermeture, et ses builds doivent exister avant que M3–M5 y soient distribués ; la mettre après obligerait à refaire des builds.

## 9. Vérifications techniques préalables

| Point | Ce qui est vérifié [F] | Ce qui reste à vérifier |
|---|---|---|
| Jetons personnalisés | aucun usage actuel dans `functions/`, `lib/` | émission, rôle de signature, session, revendications (M1, locale puis environnement autorisé) |
| Vérification de mot de passe | aucun appel REST d'identité | REST réel avec clé API : [NV] hors autorisation |
| Sessions existantes | jetons d'ID non révocables avant expiration ~1 h [H] | comportement exact : M1 |
| Phone Auth | usage dans `otp_verify_page.dart` (`signInWithCredential`) | état de production [NV] (Q12) |
| Unicité à l'inscription | contrôle client + `limit(1)` arbitraire (`index.js:1721`) | nombre de doublons réels [NV] |
| Artisans hérités | `planDocument` classe les cas (`artisanCredentials.js:12-27`) | effectifs par catégorie [NV] |
| Récupération | permission `support` et `services` existent dans les règles | personnes concernées (Q6) |
| `MinVersionService` | `min_version_service.dart:15-47`, fail-open, 0 ⇒ ok | comportement des builds réellement publiés [NV] |
| `config/app_versions` | règle lecture publique, écriture super-admin (`firestore.rules:1490-1495`) | contenu actuel en production [NV] |
| `APP_BUILD_NUMBER` | défini seulement dans `min_version_service.dart:6` et documentation ; `build_mobile.py:55-57` passe un fichier `defines` | contenu du fichier `defines` : [NV] (non lu) |
| Scripts de build | `scripts/build_mobile.py`, `ios_build_guard.py`, leurs tests | build Android sans numéro forcé ; contrat de variables à étendre |
| Versions publiées | historique Git (dates) ; AAB non suivis à la racine | versions réellement en ligne par canal : [NV] |

## 10. Plan spécifique D5 (correction du mécanisme existant)

| # | Sujet | État vérifié [F] | Correction proposée [R] |
|---|---|---|---|
| 1 | Acteurs branchés | livreur (`driver_dashboard.dart:82,1491-1495`), client (`client_dashboard.dart:74-76`), restaurateur (`restaurant_owner_dashboard.dart:65-66`) ; contrôle wallet séparé (`wallet_payment_compatibility.dart`) | conserver |
| 2 | Non couverts | vendeur, boulangerie, pharmacie, artisan, flotte, E-Kbine, agent immobilier, administrateur (aucun appel trouvé dans `lib/`) | étendre aux rôles dont les écritures seront fermées |
| 3 | Origine de `APP_BUILD_NUMBER` | `int.fromEnvironment` (`min_version_service.dart:6`), défaut 0 | l'injecter à chaque build ; le déduire du `pubspec.yaml` (`1.0.10+11` ⇒ 11) par le script plutôt que par saisie manuelle [R] |
| 4 | Scripts concernés | `scripts/build_mobile.py` + tests ; fichier `defines` [NV] | ajouter le paramètre ; faire **échouer** le build s'il est absent ou ≤ 0 ; ajouter au contrat testé |
| 5 | Build 0 ou absent | `currentBuild <= 0 ⇒ ok` (`min_version_service.dart:19`) | rendre le cas impossible côté script ; garder le repli pour les anciens binaires |
| 6 | Dialogue obligatoire | `min_version_dialog.dart` : en mode `required`, aucune action ⇒ utilisateur bloqué sans issue | bouton « Mettre à jour » + lien selon plateforme/source |
| 7 | Boutique | `url_launcher` présent (`pubspec.yaml:52`) ; pas de `in_app_update` ; iOS : seulement ouverture de fiche App Store [H] ; APK direct : page `/telecharger` | champs `storeUrl`/`downloadUrl` par plateforme ; différer la mise à jour dans l'application Play (Q10) |
| 8 | Hors connexion | échec réseau ⇒ `ok` (`min_version_service.dart:45`) | conserver ; risque post-fermeture : écritures en file rejetées [H] |
| 9 | Transition 30 jours | aucun suivi des versions [F] | calendrier L4.10.5 §9 ; suivi anonymisé ; alerte J-7 |
| 10 | Préparation ≠ fermeture | les règles ne voient pas la version ; la lecture de `config/app_versions` est publique | le dialogue prépare, **seule** M9 protège ; aucune règle fermée ici |

## 11. Risques de régression

- **Connexion client** (M3) : comptes avec alias `@azexpress.app` / `@az-seller.ci`, doublons, sessions, `reauthenticateEmail` après jeton personnalisé [H].
- **Inscription** (M4) : comptes orphelins, expérience dégradée, double inscription pendant la compensation.
- **Artisans** (M5) : blocage de profils hérités, PIN 4–5 chiffres, photos (`artisanPhotos.js` dépend de `artisanUid`).
- **Version minimale** (M2) : blocage involontaire (build mal injecté), utilisateurs sans moyen de mettre à jour, tests de `build_mobile.py`.
- **Partenaires** (M7) : flux d'approbation des vendeurs/livreurs.
- **Règles** (M9) : `permission-denied` silencieux.
- **Fichiers protégés** : `index.js`, `passwordReset.js`, `ekbineOrders.js`, `professionalSubscriptions.js`, `adminPartnerAccounts.js` ne se modifient qu'avec accord explicite ; `feexpayPayments.js` et `orderRefunds.js` ne sont jamais touchés.
- **Argent** : aucune de ces missions ne doit modifier les flux wallet ; suite de référence ≥ 2875 tests / 0 échec.

## 12. Critères d'acceptation (globaux)

Mêmes critères mesurables que L4.10.5 §13, plus : décisions Q1–Q12 consignées avant M3/M4/M5 ; M2 déployé (builds de test avec numéro ≠ 0) avant M8 ; toute mission rapporte HEAD/index/comptes avant-après ; aucune règle fermée sans M8 ; chaque déploiement faisant l'objet d'une autorisation propre.

## 13. Autorisations distinctes nécessaires

Une autorisation **par mission et par action** : M1 (création de code d'essai et exécution de tests locaux) ; M2 (modification Flutter et scripts de build, exécution de tests) ; écriture de `config/app_versions` (hors dépôt, séparée) ; M3/M4 (dont `index.js`) ; M5 (dont `passwordReset.js`) ; M7 ; M8 (communication et configuration) ; M9 (règles, **un déploiement par collection**) ; M10 (accès aux données) ; tout accès à `az-express-preprod` ; tout accès à `az-express-b0469` ; activation d'App Check, FeexPay ou suppression de compte ; commits/pushes. **Aucune autorisation globale n'est déduite de ce dossier.**

**Séparation des environnements** : production `az-express-b0469` strictement intouchable ; préproduction `az-express-preprod` sans opération sans autorisation distincte ; local : travaux existants préservés. **Vérifications locales possibles** (futures missions) : tests unitaires Node/Dart/Python, tests de règles et fonctions sur émulateurs `demo-*`, évaluation de `MinVersionService.evaluate`, tests de `build_mobile.py`, analyse statique.

## 14. Points impossibles à vérifier

Comportement réel de Firebase Auth sur ce projet (jetons, rôles IAM, REST) ; configuration « énumération d'e-mails » ; état de Phone Auth, quotas SMS ; contenu de `config/app_versions` ; contenu du fichier `defines` ; versions publiées par canal (Play, APK, App Store) ; part des anciennes versions ; nombre de doublons de numéros et de profils artisans hérités ; avis juridique ; effectifs et rôles du support ; écrans web non lus. Aucune donnée Firebase ni version publiée n'a été consultée.

## 15. Conclusion et prochaine étape

Le plan M0–M10 est cohérent. Dépendance critique : **Q12 (Phone Auth) et Q9 (canaux)** déterminent Q4, M5 et T0. Une seule contradiction a été trouvée (Q4 vs réponse uniforme). **Prochaine étape** : le propriétaire répond à Q1–Q12 (priorité Q12, Q9, Q10, Q1) ; ensuite une autorisation explicite pour **M2** et/ou **M1**. Rien ne démarre automatiquement.

**Compte rendu Git** : HEAD `d65c8f0` avant/après ; index vide avant/après ; stash 0 ; 35 fichiers suivis modifiés avant/après ; non suivis 169 avant, **170 après** (ce rapport). Empreintes protégées à vérifier dans le message final.
