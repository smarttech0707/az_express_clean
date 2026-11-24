# Mission M2.1 — Finalisation du contrôle des versions

Travaux **locaux** uniquement. Aucun accès Firebase (production, préproduction ou projet distant), aucune écriture dans `config/app_versions`, aucune règle, IAM, secret ni lien distant modifié, aucun déploiement ni publication, aucun commit/push/stash/reset/checkout. **T0 n'est ni défini ni activé.** Légende : **PASS** vérifié ; **NON VÉRIFIÉ** ; **BLOQUÉ**.

## 1. Verdict par critère de validation

| Critère | Statut |
|---|---|
| Procédures de compilation autorisées utilisent le contrôle obligatoire du numéro | **PASS** pour `run.ps1`, `scripts/build_mobile.py`, `android-release.md`, `MOBILE_FIREBASE_BUILD.md` (vérifié par exécution à blanc, voir §3). Contournements restants listés §7 |
| Numéro de build vérifié dans un **véritable binaire local** | **BLOQUÉ** (APK Android) / **NON VÉRIFIÉ** (IPA). Vérifié seulement dans l'exécutable natif d'une sonde et dans la VM de test sur le vrai code du projet (§4) — **ce n'est pas un APK** |
| Couverture de l'administrateur mobile établie | **PASS** (§5) |
| Limites documentées | **PASS** (§7–8) |
| Tests pertinents passent | **PASS** (§6) |
| Aucun accès Firebase distant / déploiement / config distante | **PASS** |

**M2.1 ne peut donc pas être déclarée entièrement validée** : la vérification dans un binaire du projet n'a pas pu être réalisée.

## 2. Contrôles préalables [F]

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0 ; 49 fichiers suivis modifiés et 175 non suivis au départ. Aucun des fichiers cibles (`run.ps1`, `.claude/rules/android-release.md`, `docs/MOBILE_FIREBASE_BUILD.md`, `admin_dashboard.dart`) ne contenait de modification préexistante (`git status` vierge pour eux). `scripts/m1_feasibility/` et les rapports M1/M2 sont intacts.

## 3. A — Alignement des procédures de compilation

`run.ps1` (modifié, paramètres `-release` et `-build` conservés) :
- Déduit `APP_BUILD_NUMBER` de `pubspec.yaml` (`+N`) ; **refus** (code 1) si absent/nul, ou si `APP_BUILD_NUMBER` figure dans `.env`. Messages en ASCII (évite la mauvaise lecture d'encodage de Windows PowerShell 5.1).
- `-build apk|appbundle|ipa` **délègue à `scripts/build_mobile.py`** (avec `--config` = le `.env` du dossier courant, pour apk/appbundle ; l'ipa lit son plist) ; `-build web` inchangé (le web n'a pas de numéro) ; autres cibles et `flutter run` reçoivent `--dart-define=APP_BUILD_NUMBER=<N>`.
- Nouveau paramètre `-DryRun` : affiche la commande sans lancer Flutter ni Python (sert aux tests).

Vérification par exécution à blanc depuis un dossier temporaire contenant un faux `.env` (le vrai `.env` n'a **pas** été lu) :
`run.ps1 -DryRun` → `flutter run … --dart-define=APP_BUILD_NUMBER=11` ; `-release` → idem `--release` ; `-build apk` / `appbundle` → `py …\scripts\build_mobile.py <cible> --config <.env courant>` ; `-build ipa` → `py …\build_mobile.py ipa` ; `-build web` → `flutter build web --dart-define-from-file=.env` ; `-build ios` → avec `APP_BUILD_NUMBER=11` ; `.env` contenant la clé ⇒ refus ; pas de `.env` ⇒ refus. **PASS** (aucune commande réelle exécutée).

Documents alignés : `.claude/rules/android-release.md:18` (build de release via le script, plus de `flutter build appbundle --release` direct) ; `docs/MOBILE_FIREBASE_BUILD.md` (paragraphe sur `APP_BUILD_NUMBER`).

## 4. C — Vérification de la valeur dans des binaires

| Essai | Résultat |
|---|---|
| Exécutable natif (`dart compile exe -DAPP_BUILD_NUMBER=…`) avec la **même déclaration** `int.fromEnvironment('APP_BUILD_NUMBER')` | `11`→11 ; **absent→0** ; **`abc`→0** ; **`0`→0** ; `-5`→-5 ; `4242424`→4242424 **PASS** |
| `flutter test` sur le **vrai** `lib/services/min_version_service.dart`, avec le fichier de défines JSON produit par les fonctions de `build_mobile.py` (valeur écrite en chaîne) | marqueur 4242424 lu = 4242424 ; fichier sans clé → 0 ; `abc` → 0 ; `0` → 0 ; `-5` → -5 ; dans les cas ≤ 0, `evaluate(enforce:true)` renvoie `ok` **PASS** (VM de test, pas un binaire livrable) |
| Build web du projet (sortie hors dépôt, configuration factice) | Compilation réussie (138 s) mais **sans valeur** : le code de version minimale **n'est pas compilé dans le web** (aucune occurrence de `minBuild`), donc preuve **sans objet** pour ce cas ; `build/web` existant vérifié identique avant/après |
| `flutter build apk --debug` avec défines factices | **BLOQUÉ** : `Could not download gradle-8.0.2.jar … dl.google.com … Read timed out` (cache Gradle purgé lors du nettoyage précédent, dépendances à retélécharger, réseau en délai dépassé), après 11 min. Arrêt volontaire : l'espace libre sur C: est passé de 6,5 à **3,7 Go**. Aucun APK produit. `app-release.apk` existant inchangé (SHA-1 identique avant/après) |
| IPA | **NON VÉRIFIÉ** (macOS requis) |

Conséquence : la présence de `APP_BUILD_NUMBER` **dans un APK ou IPA** du projet reste **NON VÉRIFIÉE**. Ce qui est établi : le script écrit la clé (tests Python), `int.fromEnvironment` la lit correctement dans une VM de test et dans un exécutable natif, absente/invalide/0 ⇒ 0 ⇒ jamais bloqué.

## 5. B — Administrateur mobile

- Point d'entrée unique [F] : `AdminDashboard` (construit seulement par `admin_login.dart:227` et `admin_otp_page.dart:407` ; `home_screen.dart:97` mène à `AdminLogin`). Aucun fichier hors `lib/screens/admin/` et `lib/web/` n'importe les écrans admin ; les sous-écrans `admin_ai_dashboard.dart` et `admin_security_dashboard.dart` ne sont importés que par `admin_menu.dart` (depuis `AdminDashboard`).
- Modification (faible risque, même schéma que les autres rôles) : `admin_dashboard.dart` appelle `showMinVersionDialogIfNeeded(context, minVersionRoleAdmin, …)` dans la branche de session valide (le contrôle de session existant n'est pas modifié). Constante `minVersionRoleAdmin = 'admin'` ajoutée. Sans entrée `admin` dans `config/app_versions` : **aucun effet**.
- Contournements restants : **web admin** (`web_admin_dashboard.dart`, build 0 : jamais bloqué) — c'est aussi la voie de secours pour corriger la configuration si un blocage mal réglé touchait l'application mobile ; ancien binaire sans le contrôle ; build à 0.
- Test statique de couverture mis à jour : l'administrateur est désormais « couvert » ; les sous-écrans restent exclus avec raison.

## 6. Tests exécutés (résultats exacts)

| Commande | Résultat |
|---|---|
| `flutter test` : `min_version_service_test`, `min_version_coverage_test`, `min_version_dialog_test`, `min_version_build_number_define_test`, `partner_first_login_test` | **40 réussis, 1 ignoré** (le test de define sans variable), 0 échec |
| `flutter test --dart-define-from-file=<marqueur> --dart-define=EXPECTED_APP_BUILD_NUMBER=4242424 …define_test` et 4 variantes (fichier sans clé, `abc`, `0`, `-5`) | 5 exécutions, toutes réussies |
| `py -m unittest test_build_mobile test_ios_build_guard` | **42 tests, OK** |
| `flutter analyze` (`admin_dashboard.dart`, dialogue, service, `test/services`) | **No issues found** |
| `run.ps1 -DryRun` (8 cas) | conforme (§3) |
| `flutter build web` (sortie hors dépôt) | réussi (preuve sans objet, §4) |
| `flutter build apk --debug` | **ÉCHEC réseau** (BLOQUÉ) |

Non lancés : suite complète `flutter test`, `flutter analyze` globale, `npm test`, tests d'émulateurs.

## 7. Contournements restants

1. `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md:14,18,96,100` : `flutter run`/`flutter build apk --debug --dart-define-from-file=.env` directs ⇒ build à 0 (tests sur appareil). Non modifié (non autorisé).
2. `test-env/build-emulator-apk.ps1` et `test-env/build-test-apk.ps1` : builds de débogage pour émulateurs, sans le numéro. Non modifiés.
3. `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md:91` et `docs/ACCOUNT_DELETION_LOCAL_STATUS.md:27` citent `flutter build appbundle --release` direct : le premier porte des modifications non validées préexistantes (**non touché**), le second non modifié.
4. Un `flutter build` direct dans un terminal reste techniquement possible ; seul le processus documenté l'interdit.
5. Les binaires déjà publiés (probablement à 0) et le web restent non bloquables.

## 8. Limites et risques

- Aucun APK/IPA du projet n'a été produit : l'injection dans un vrai binaire est **NON VÉRIFIÉE**. Pour la finir : réseau fonctionnel vers `dl.google.com` et espace disque suffisant, ou un build sur un poste/CI où le cache Gradle est présent (`py scripts/build_mobile.py apk` avec un `.env` autorisé).
- **Effet de bord à connaître** : la tentative de build a retéléchargé une partie du cache Gradle (`C:\Users\User\.gradle`), ≈ 2,8 Go d'espace libre en moins. Rien n'a été supprimé (aucune autorisation de nettoyage dans M2.1). Le fichier suivi `android/build/reports/problems/problems-report.html` a été modifié par Gradle ; je l'ai **réécrit à l'identique de HEAD** (`git show`, sans checkout) ; l'index n'a pas été touché.
- Le contrôle de version reste une barrière d'expérience, pas de sécurité (les règles ne voient pas la version).
- Un blocage `enforce:true` sans lien de mise à jour n'offre aucun bouton ; liens et donnée `config/app_versions` restent à autoriser séparément.
- Mode lecture seule : non traité (voir M2).
- Le suivi anonymisé, le tableau de bord et l'alerte J-7 : non touchés.

## 9. Fichiers

Modifiés (M2.1, 4 fichiers suivis) : `run.ps1`, `.claude/rules/android-release.md`, `docs/MOBILE_FIREBASE_BUILD.md`, `lib/screens/admin/admin_dashboard.dart`. Déjà modifiés par M2 et retouchés : `lib/widgets/min_version_dialog.dart` (constante admin), `test/services/min_version_coverage_test.dart` (non suivi). Créés : `test/services/min_version_build_number_define_test.dart`, ce rapport. Hors dépôt (dossier temporaire de session) : défines factices, sonde Dart, sorties de build, copie de sauvegarde de `build/web` (jamais nécessaire).

## 10. État Git

| | Avant M2.1 | Après M2.1 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index | vide | vide |
| Stash | 0 | 0 |
| Fichiers suivis modifiés | 49 | **53** (+4) |
| Fichiers non suivis | 175 | **177** (test de define + ce rapport) |

Empreintes inchangées : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. `build/web` (manifeste) et `app-release.apk` (SHA-1) inchangés. Aucune opération Firebase ni émulateur.

## 11. Décisions / autorisations nécessaires

1. Retenter le build Android (réseau fonctionnel + espace disque), ou un build sur Mac/CI pour l'IPA.
2. Nettoyer le cache Gradle regénéré ? (autorisation explicite requise ; je n'ai rien supprimé).
3. Aligner `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md`, `test-env/*.ps1` et le checklist de suppression de compte (fichier préexistant modifié : stratégie à décider).
4. Liens de mise à jour par canal et écriture de `config/app_versions`.

**Arrêt : aucune autre mission lancée.**
