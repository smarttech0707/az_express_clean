# Mission M2 — Fiabilisation du mécanisme de version minimale

Travaux **locaux** uniquement : aucun accès Firebase, aucune modification de `config/app_versions`, de règles, d'IAM, de secrets ou de configuration distante ; aucun déploiement, commit, push ou stash. **T0 n'est ni défini ni activé.** Légende : **[F]** fait lu dans le dépôt ; **[T]** testé localement (résultat exact indiqué) ; **[H]** hypothèse ; **[NV]** non vérifiable ici.

## 1. Verdict

**M2 est réussie sur ce qui était vérifiable localement, mais pas « entièrement » :** le mode lecture seule n'est **pas** réalisable de façon sûre à ce stade (§7, non implémenté), aucun lien de mise à jour par défaut n'a été inventé (§6), et l'effet réel sur les binaires publiés, sur `config/app_versions` et sur les boutiques reste **non vérifié** (§10).

## 2. Audit de l'existant [F]

- `MinVersionService` (`lib/services/min_version_service.dart`) : lit `config/app_versions.<rôle>` ; `evaluate` : `currentBuild <= 0` ou configuration absente/invalide ⇒ `ok` ; erreur réseau ⇒ `ok` (jamais bloqué hors connexion).
- `APP_BUILD_NUMBER` : lu par `int.fromEnvironment` ; **cause racine du build à 0** : `scripts/build_mobile.py` (chemin documenté pour APK/AAB/IPA, `docs/MOBILE_FIREBASE_BUILD.md`, `codemagic.yaml:98,170,290,362`) écrivait un fichier `defines.json` contenant **uniquement** les variables Firebase ; la valeur n'était jamais injectée. Conséquence [H, binaires non inspectés] : les builds produits par ce script déclaraient 0 ⇒ jamais bloqués.
- Autres chemins qui contournent le script : `run.ps1:17` (`flutter build … --dart-define-from-file=.env`), `.claude/rules/android-release.md:18` (`flutter build appbundle --release` direct), builds web (`docs/DISTRIBUTION_ANDROID.md:23`). Ils produisent un build à 0.
- Dialogue (avant M2) : en mode obligatoire, aucun bouton ⇒ utilisateur bloqué sans issue.
- Le livreur dupliquait la boîte de dialogue dans `driver_dashboard.dart`.

## 3. Rôles couverts et non couverts

| Rôle (clé `config/app_versions`) | Avant M2 | Après M2 | Fichier |
|---|---|---|---|
| `driver` | oui (code dupliqué) | oui (boîte partagée) | `driver_dashboard.dart` |
| `client` | oui | oui | `client_dashboard.dart` |
| `restaurant` | oui | oui | `restaurant_owner_dashboard.dart` |
| `seller` | non | **oui** | `seller_dashboard.dart` |
| `boulangerie` | non | **oui** | `boulangerie_dashboard.dart` |
| `pharmacie` | non | **oui** | `pharmacie_dashboard.dart` |
| `artisan` | non | **oui** | `artisan_dashboard.dart` |
| `fleet` | non | **oui** | `fleet_dashboard.dart` |
| `immobilier` | non | **oui** | `agent_dashboard_screen.dart` |
| `ekbine` | non | **oui** | `ekbine/screens/ek_agent_dashboard.dart` |
| Administrateur (mobile) | non | **oui, ajouté après ce rapport** (clé `admin`, vérifié le 2026-11-12 dans `admin_dashboard.dart:55`) | `admin_dashboard.dart` ; les sous-écrans admin y sont atteints |
| Web (client, admin) | non | **non couvert, par conception** : pas de numéro de build, se met à jour au déploiement | `web_*_dashboard.dart` |

Un contrôle statique (`test/services/min_version_coverage_test.dart`) échoue si un nouveau `*_dashboard.dart` n'est ni branché ni explicitement exclu. Il a d'ailleurs détecté deux tableaux de bord web que j'avais oubliés dans la liste d'exclusion (corrigé).

Sans entrée du rôle dans `config/app_versions`, **aucun effet** : l'ajout des appels est inerte tant que la donnée n'est pas écrite (autorisation séparée).

## 4. Comportement de `APP_BUILD_NUMBER` absent ou nul

- **Script de build** (modifié) : `resolve_build_number` prend la surcharge IPA (`--build-number`) sinon le `+N` de `pubspec.yaml` (`1.0.10+11` ⇒ 11, identique au `versionCode` Android et à la valeur embarquée par Flutter). Refus (code de sortie 2, message sans valeur sensible) si le numéro est absent, ≤ 0 ou si `APP_BUILD_NUMBER` figure déjà dans le fichier de configuration. Le contrôle s'exécute aussi avec `--check-only`. La valeur est ajoutée au fichier de défines temporaire.
- **Application** (inchangé) : build 0 ⇒ `ok` (nécessaire pour les anciens binaires, le web et les builds hors script). Ce repli est volontaire ; il rend le contrôle inopérant sur tout build qui contourne le script.
- **Mise à jour 2026-11-12** : `run.ps1` délègue désormais `apk`/`appbundle`/`ipa` à `scripts/build_mobile.py` et calcule `APP_BUILD_NUMBER` (via le même `+N`) pour `run`/autres cibles ; la règle `.claude/rules/android-release.md` impose le script. Reste vrai : rien n'empêche techniquement un `flutter build` direct lancé à la main, ni le build web (volontairement à 0).

## 5. Plateformes : clés par plateforme

Les numéros Android (`versionCode` = pubspec) et iOS (`IOS_BUILD_NUMBER` surchargé) peuvent diverger. `config/app_versions.<rôle>` accepte désormais, **en option**, `minBuildAndroid` / `minBuildIos` (priment sur `minBuild`) et `updateUrlAndroid` / `updateUrlIos` (priment sur `updateUrl`). Une clé absente ou invalide est ignorée. Aucune donnée n'a été écrite.

## 6. Fenêtre de mise à jour et liens

- Bouton « Mettre à jour » **uniquement** si `config/app_versions` fournit un lien qui passe `safeUpdateUrl` : `https`, sans identifiants, hôte parmi `az-express-b0469.web.app`, `play.google.com`, `apps.apple.com`. Tout autre lien (http, hôte voisin, `javascript:`, `market:`) est ignoré [T].
- **Aucun lien par défaut n'est codé.** Constat [F] : la seule URL exacte existante est `https://az-express-b0469.web.app/telecharger/` (`partner_qr_page.dart:176`, paquet QR isolé, non modifié) et `downloadUrl` de `web/distribution/latest.json` ; les liens Play et App Store du code sont génériques (`https://play.google.com`, `https://apps.apple.com`, `home_page.dart:193-222`) et **aucun lien exact de fiche d'application n'existe**. Diriger un utilisateur Google Play vers l'APK direct serait nuisible : la signature de l'APK diffère de celle de Play (`docs/DISTRIBUTION_ANDROID.md`) ; l'origine d'installation n'est pas détectable sans dépendance (non autorisée ici, `in_app_update` exclu).
- Conséquence : tant que la donnée n'est pas écrite, un blocage `enforce:true` affiche le message sans bouton. **Décision requise** (§11).

## 7. Mode lecture seule — faisabilité réelle

**Non démontrée comme sûre ; non implémentée.**
- Inventaire [F, `grep` indicatif, surestime] : 159 fichiers de `lib/` contiennent des écritures ou appels de fonctions ; `.set(` 71, `.update(` 131, `.add(` 281 (inclut des ajouts de listes), `.delete(` 65, `httpsCallable(` 82, transactions 18, lots 9, envois de fichiers 35. Il n'existe **aucun point central d'écriture** à protéger.
- Un « drapeau » global testé à ces points exigerait de modifier des centaines d'appels, avec un risque de laisser un chemin d'argent ouvert ou de bloquer un chemin légitime (annulation, litige) ; une version ancienne n'exécute de toute façon que son propre code, y compris sans drapeau.
- **Le seul mécanisme réellement contraignant est la fermeture des règles Firestore côté serveur (M9)** : les anciennes versions deviennent de fait en lecture seule, avec des échecs `permission-denied` silencieux. Le contrôle de version ne fait que préparer et informer.
- Aucun échafaudage inutilisé n'a été ajouté (règle projet : pas de code sans consommateur). Étude possible plus tard : écran « lecture seule » explicite et gestion centralisée de `permission-denied`.

## 8. Fichiers modifiés

Modifiés (14, tous sans modification préexistante au départ, vérifiée par `git status`) : `scripts/build_mobile.py`, `scripts/test_build_mobile.py`, `lib/services/min_version_service.dart`, `lib/widgets/min_version_dialog.dart`, `lib/screens/driver/driver_dashboard.dart`, `lib/screens/seller/seller_dashboard.dart`, `lib/screens/boulangerie/boulangerie_dashboard.dart`, `lib/screens/pharmacie/pharmacie_dashboard.dart`, `lib/screens/artisan/artisan_dashboard.dart`, `lib/screens/fleet/fleet_dashboard.dart`, `lib/screens/immobilier/agent_dashboard_screen.dart`, `lib/ekbine/screens/ek_agent_dashboard.dart`, `test/services/min_version_service_test.dart`, `test/widgets/min_version_dialog_test.dart`.
Créés : `test/services/min_version_coverage_test.dart`, ce rapport.
Changement d'API interne : `MinVersionService.check` renvoie un enregistrement à 3 champs (`status, message, updateUrl`) ; aucun autre appelant que le dialogue (vérifié par recherche).
Non touchés : `scripts/m1_feasibility/` et `docs/ACCOUNT_DELETION_M1_LOCAL_FEASIBILITY.md` (préservés), fichiers protégés, `firestore.rules`, `storage.rules`, `pubspec.yaml`, `pubspec.lock`, `run.ps1`, `codemagic.yaml`.

## 9. Tests exécutés (résultats exacts)

| Commande | Résultat |
|---|---|
| `py -m unittest test_build_mobile` (avant modification) | 9 tests, OK |
| `py -m unittest test_build_mobile test_ios_build_guard` (après) | **42 tests, OK** (`test_build_mobile` seul : 16 tests, OK) |
| `flutter test test/services/min_version_service_test.dart test/services/min_version_coverage_test.dart test/widgets/min_version_dialog_test.dart` | **20 tests, tous réussis** (une première exécution a échoué sur le contrôle de couverture ; corrigé) |
| `flutter test test/screens/auth/partner_first_login_test.dart` (seul test référençant un tableau de bord) | **19 tests, tous réussis** |
| `flutter analyze` sur les 10 fichiers de code modifiés + `test/services` + test du dialogue | 0 erreur ; 12 infos, **toutes préexistantes** dans `agent_dashboard_screen.dart` (lignes ≠ de mes ajouts) |
| `py scripts/build_mobile.py apk --config <fichier factice> --check-only` | `validation PASS … APP_BUILD_NUMBER=11`, code 0 |
| idem avec `APP_BUILD_NUMBER` dans la configuration | refus, code 2 |
| idem avec `--build-number 0` | refus (argparse), code 2 |

Les essais du script ont utilisé un **fichier de configuration factice** hors dépôt : `.env` réel non lu. La suite complète `flutter test`, `flutter analyze` globale, `npm test` et tout test d'émulateur n'ont **pas** été lancés. Aucun build réel (`flutter build`) n'a été exécuté, donc la présence effective de `APP_BUILD_NUMBER` dans un binaire n'est **pas** vérifiée de bout en bout.

## 10. Limites et risques restants

- **[NV]** Valeur de `APP_BUILD_NUMBER` dans les binaires déjà publiés (probablement 0 s'ils viennent du script d'avant M2) ; ces versions ne seront jamais invitées à mettre à jour.
- **[NV]** Contenu de `config/app_versions` en production ; aucune donnée écrite.
- **[H]** `--dart-define-from-file` accepte la valeur chaîne `"11"` et `int.fromEnvironment` la lit : non vérifié par un build réel.
- Contournements possibles du script (`run.ps1`, build direct, web) ⇒ build 0 ⇒ non bloquable.
- Divergence de numérotation Android/iOS à gérer dans la donnée (clés par plateforme).
- Barrière d'expérience, pas de sécurité : les règles ne voient pas la version ; un client modifié ignore le contrôle.
- Suivi anonymisé des versions, tableau de bord et alerte J-7 : **non réalisés** (nécessitent fonction serveur et donnée : hors périmètre local de M2).
- `package_info_plus` : étudié seulement comme contrôle complémentaire, **non ajouté** (aucune dépendance ajoutée).
- ~~Admin mobile non couvert~~ : couvert depuis (voir §3).

## 11. Points nécessitant une décision ou une autorisation distincte

1. Lien(s) de mise à jour exact(s) par plateforme et par canal (Play, APK direct, App Store) et autorisation d'écrire `config/app_versions` ; dans l'immédiat aucun lien n'est valable pour tous.
2. ~~Aligner `run.ps1` et la règle `android-release.md` sur le script~~ : fait depuis (voir §4).
3. ~~Couvrir l'administrateur mobile ?~~ : fait depuis (voir §3).
4. Mode lecture seule : accepter que la fermeture des règles (M9) en tienne lieu, ou financer une étude de gestion centralisée de `permission-denied`.
5. Suivi anonymisé, tableau de bord, alerte J-7 : mission séparée avec fonction serveur.
6. Définition de T0 et construction des binaires intégrant ce mécanisme (build puis publication : autorisation séparée).

## 12. État Git

| | Avant M2 | Après M2 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index | vide | vide |
| Stash | 0 | 0 |
| Fichiers suivis modifiés | 35 | **49** (+14, listés §8) |
| Fichiers non suivis | 173 | **175** (test de couverture + ce rapport) |

Empreintes des fichiers protégés inchangées : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. Aucune opération Git d'écriture ; aucune opération Firebase ; aucun émulateur lancé ni arrêté.

**Arrêt :** M3 et toute autre mission restent à autoriser séparément.

## 13. Mise à jour M2.1 (2026-11-12) — robustesse de la lecture

Modifications locales uniquement (aucune règle, fonction, donnée distante ni activation). Comportement vérifié par les tests (`test/services/min_version_service_test.dart`).

- **Validation champ par champ** dans `MinVersionService.check` : `message`, `minBuild` (et variantes de plateforme), `enforce`, liens sont validés séparément. Avant : un `message` non textuel levait une `TypeError` rattrapée par le `catch` global, ce qui renvoyait `ok` et neutralisait une obligation valide.
- **Table de traitement des valeurs** (aussi dans la documentation de la classe) :

| Champ | Valide | Traitement si invalide |
|---|---|---|
| `minBuild`, `minBuildAndroid`, `minBuildIos` | entier, ou décimal entier (`14.0`), de 1 à 2 100 000 000 | champ ignoré : refusés texte, booléen, `null`, liste, 0, négatif, NaN, infini, fractionnaire (`14.5`, jamais arrondi), valeur trop grande. Clé de plateforme refusée ⇒ `minBuild` commun ; pas de `minBuild` valide ⇒ aucune contrainte |
| `enforce` | booléen `true` | toute autre valeur ⇒ simple recommandation (jamais de blocage) |
| `message` | texte non vide de 500 caractères au plus | ignoré, message par défaut de l'écran ; jamais tronqué |
| `updateUrl*` | https, hôte autorisé, sans identifiants | pas de bouton « Mettre à jour » ; l'obligation reste |
| entrée du rôle | table | absente ou autre type ⇒ aucune contrainte |
| lecture du document | réussie | échec (hors ligne, permission, délai) ou erreur inattendue ⇒ aucune contrainte, comme avant |

- **Source injectable** : `MinVersionService({MinVersionSource? source})` ; sans argument, lecture de `config/app_versions` comme avant. L'appelant existant (`MinVersionService().check`) est inchangé.
- **Tests** : 41 tests réussis (1 ignoré : `EXPECTED_APP_BUILD_NUMBER` non fourni) sur les 4 fichiers de version minimale ; `flutter analyze` sans problème sur le périmètre ; fixture de `rules-tests/config-financial.rules.test.js` corrigée (`driver` au lieu de `livreur`, 6 tests réussis sur émulateur isolé).
- **Non fait (hors M2.1)** : écriture serveur validée et auditée de `app_versions`, revérification au retour au premier plan, `enforce` par plateforme, tests d'intégration du câblage des écrans, M9.

## 14. Mise à jour M2.2 (2026-11-12) — configuration sécurisée de `config/app_versions`

**Local uniquement : rien déployé, aucune configuration distante modifiée, `enforce:true` jamais activé.**

- **Fonction** `setAppVersionsConfigCF` (`functions/appVersionsAdmin.js`, export dans `functions/index.js`, `maxInstances:1`, `cpu:0.5`). Entrée : `{ role, expectedVersion, values }` (`values: null` retire l'entrée du rôle). Réponse : enveloppe `{success, error, message, data, code}`.
- **Autorisation** : `requireSuperAdmin` (admin actif, rôle `super`, MFA selon `ADMIN_MFA_MODE`) ; un sous-admin, un admin désactivé, un anonyme ou un inconnu sont refusés. Débit : 10 modifications/heure/admin.
- **Validation** : rôle parmi les 11 rôles connus ; champs connus seulement (`minBuild`, `minBuildAndroid`, `minBuildIos`, `updateUrl*`, `message`, `enforce`) ; builds entiers 1..2 100 000 000 ; message 1..500 caractères ; liens https, hôtes `az-express-b0469.web.app`, `play.google.com`, `apps.apple.com`, sans identifiants. Règles alignées sur `MinVersionService`.
- **`enforce`** : `true` refusé (`ENFORCE_NOT_ALLOWED`). Un rôle déjà en blocage ne se modifie qu'avec `enforce:false` explicite.
- **Concurrence** : champ `version` du document, `expectedVersion` obligatoire (0 si document absent), transaction.
- **Garde du dernier build publié** : le dépôt ne le connaît pas (Play Console / App Store Connect inconnus ; seul `web/distribution/latest.json` = APK direct, build 11). Il n'est donc **jamais déduit**. Source : `config/app_release_registry` = `{android:{latestBuild,source,verifiedAt}, ios:{...}}`, à écrire **à la main via Admin SDK** après lecture de la console du store. Registre absent/invalide ⇒ impossible de définir ou relever un `minBuild` (`PUBLISHED_BUILD_UNVERIFIED`) ; `minBuild` > dernier build vérifié ⇒ `BUILD_ABOVE_PUBLISHED`. Baisser, conserver ou retirer reste permis. **Besoin documenté : une procédure (décision propriétaire) pour renseigner ce registre avant toute politique réelle.**
- **Audit** : `audit_logs` action `app_versions_config_update`, auteur, rôle cible, valeur avant/après, version ; refus journalisés (`status:'refused'`, code).
- **Règles** : `config/app_versions` et `config/app_release_registry` n'acceptent plus aucune écriture cliente, super-admin compris ; lectures inchangées (`app_versions` public, registre super-admin). Aucun écrivain Flutter/functions/script de `app_versions` n'existait (recherche dans le dépôt) : aucun module cassé ; le seul écrivain est désormais la fonction.
- **Tests** : `functions/test/appVersionsAdmin.test.js` (9), `appVersionsAdmin.emulator.test.js` (2, Firestore émulé), `rules-tests/config-financial.rules.test.js` (+1).
