# Mission M2.3 — Alignement des documents et procédures

Travail **documentaire local** uniquement : aucun build (Android, App Bundle, IPA, Web), aucun test d'émulateur, aucun nettoyage de cache, aucun accès Firebase, aucune écriture dans `config/app_versions`, aucune règle/IAM/secret modifié, aucun lien de mise à jour changé, aucun déploiement. Aucune commande Git d'écriture. T0 n'est ni défini ni activé.

## 1. Verdict

| Critère | Statut |
|---|---|
| Les quatre documents sont cohérents avec les scripts actuels | **PASS** (références croisées vérifiées, §4) |
| Aucune procédure ne recommande de contourner la validation du numéro | **PASS** pour les 4 documents. **Une occurrence subsiste dans la checklist de suppression de compte (exclue, §5)** |
| Checklist de suppression de compte strictement intacte | **PASS** (empreinte, taille et date identiques avant/après) |
| Aucun accès distant, build ou déploiement | **PASS** |
| Injection du numéro dans un APK/IPA réel | **NON VÉRIFIÉE** — signalé comme tel dans chaque document modifié |

## 2. État initial [F]

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0 ; 56 fichiers suivis modifiés, 180 non suivis. Les quatre fichiers cibles sont suivis et **sans modification préexistante** (`git status` vierge pour eux). Checklist : modifiée localement (travail non validé préexistant), empreinte `8a130216a032b6577a39f148f805d9f2a15ae789`, 17 702 octets, modifiée le 2026-11-06 18:32:09 UTC.

## 3. Modifications (15 lignes ajoutées, 11 retirées, tous les fichiers en UTF-8 sans changement de fins de ligne)

| Document | Changement |
|---|---|
| `test-env/README-EMULATEURS.md` | Précise que `build-emulator-apk.ps1` calcule `APP_BUILD_NUMBER` et annule le build s'il est invalide ; équivalent manuel (déconseillé) complété par `--dart-define=APP_BUILD_NUMBER=<N>` pris dans `scripts\get-app-build-number.ps1` ; mention : script modifié non exécuté de bout en bout, injection dans l'APK **non vérifiée** |
| `docs/PROTOCOLE_TESTS_LANCEMENT.md` §6–§7 | Distingue **niveau A (test, émulateurs)** → `build-emulator-apk.ps1` ; **appareil de développement (local)** → `.\run.ps1 -Device <id>` ; **niveau B et publication** → `py scripts/build_mobile.py appbundle` à la place de `flutter build appbundle --release` (« jamais en direct », avec la raison : un build à 0 n'est jamais invité à se mettre à jour) ; iPhone : `python3 scripts/build_mobile.py ipa --build-number "$IOS_BUILD_NUMBER"`, pas `flutter build ipa` ; injection dans AAB/APK/IPA marquée non vérifiée |
| `docs/ACCOUNT_DELETION_LOCAL_STATUS.md` §« Commandes futures » | Android : `py scripts/build_mobile.py appbundle` ; iOS : `python3 scripts/build_mobile.py ipa --build-number "$IOS_BUILD_NUMBER"` ; pas de `flutter build` direct pour une release ; phrases existantes (« non exécutées », « ne publient pas ») conservées ; injection non vérifiée |
| `docs/PUBLICATION_1_0_10_PLAN.md` | Étape Hosting : `.\run.ps1 -build web` (équivalent de la commande précédente, web sans numéro de build) ; étape Application : AAB produit par `build_mobile.py appbundle` ; nouveau prérequis `APP_BUILD_NUMBER` (avec « NON VÉRIFIÉE : présence dans l'AAB réel ») ; ligne Version/build : `IOS_BUILD_NUMBER` est aussi injecté comme `APP_BUILD_NUMBER`, plage 1–2 100 000 000, réglage iOS via `minBuildIos` ; §8.3 et IOS « À tester » : build IPA via le script, présence du numéro dans l'IPA **NON VÉRIFIÉE** |

Aucun contenu métier (lots de déploiement, rollback, listes de blocages) n'a été réécrit.

## 4. Vérifications effectuées (statiques)

- Les fichiers référencés existent : `scripts/build_mobile.py`, `scripts/get-app-build-number.ps1`, `run.ps1`, `docs/MOBILE_FIREBASE_BUILD.md`, `docs/IOS_MAC_BUILD_GUIDE.md`, `test-env/build-emulator-apk.ps1`, `test-env/install-test-apk.ps1`.
- Cohérence avec les scripts : `run.ps1 -build web` produit `flutter build web --dart-define-from-file=.env` (exécution à blanc faite en M2.1/M2.2) ; `run.ps1 -Device` existe (M2.2) ; `minBuildIos` existe dans `min_version_service.dart` ; plage 1–2 100 000 000 identique dans `build_mobile.py` et l'assistant PowerShell ; `build-emulator-apk.ps1` ajoute bien le numéro (M2.2).
- Recherche textuelle de `flutter build (appbundle|ipa|apk)` et `flutter run` dans les quatre documents : les seules occurrences restantes sont l'équivalent manuel du README (numéro ajouté, déconseillé) et des phrases qui **interdisent** la commande directe.
- Contrôle de la checklist : empreinte, taille et date inchangées (`8a130216…`, 17 702 octets, 2026-11-06 18:32:09).

Non fait : aucune exécution de script de build, aucune relecture sémantique des commandes sur Mac/Codemagic. **NON VÉRIFIÉE** : le fonctionnement de bout en bout de `build-emulator-apk.ps1` modifié et la présence réelle de `APP_BUILD_NUMBER` dans un binaire.

## 5. Checklist de suppression de compte — signalement uniquement

`docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md`, ligne 91 : « Android : `flutter build appbundle --release` … iOS : sur Mac, `flutter build ipa --release` … » — commandes **directes** qui contournent le contrôle du numéro de build. **Non modifiée** (interdiction). Mise à jour recommandée, à autoriser séparément : remplacer par `py scripts/build_mobile.py appbundle` et `python3 scripts/build_mobile.py ipa --build-number "$IOS_BUILD_NUMBER"`. La stratégie de fusion avec les modifications locales non validées du fichier reste à définir.

## 6. Contournements restants

1. La ligne 91 de la checklist ci-dessus.
2. Un `flutter build`/`flutter run` tapé directement reste possible ; seules les procédures documentées sont alignées.
3. Les binaires déjà publiés et le web restent non bloquables (build 0).
4. Documents non listés dans M2.3 pouvant citer des commandes directes : non recensés exhaustivement en dehors des fichiers déjà traités (`docs/DISTRIBUTION_ANDROID.md` cite `flutter build web --release --dart-define-from-file=.env`, légitime pour le web).

## 7. Éléments NON VÉRIFIÉS

Présence de `APP_BUILD_NUMBER` dans un APK/AAB/IPA ; exécution de `test-env/build-emulator-apk.ps1` et `build-test-apk.ps1` ; contenu de `config/app_versions` et versions publiées ; parcours Codemagic et Mac.

## 8. État Git

| | Avant M2.3 | Après M2.3 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index | vide | vide |
| Stash | 0 | 0 |
| Fichiers suivis modifiés | 56 | **60** (+4 documents) |
| Fichiers non suivis | 180 | **181** (ce rapport) |

Empreintes inchangées : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. Travaux M1, M2, M2.1, M2.2 et tous les fichiers non suivis préservés.

## 9. Décisions nécessaires

1. Autoriser la mise à jour de la ligne 91 de la checklist de suppression de compte (et décider comment la rattacher à ses modifications locales non validées).
2. Autoriser un build réel (Android avec réseau/espace disque, IPA sur Mac ou Codemagic) pour lever les « NON VÉRIFIÉE ».
3. Autoriser le nettoyage du cache Gradle regénéré (≈ 2,8 Go).
4. Liens de mise à jour par canal et écriture de `config/app_versions`.

**Arrêt : aucune autre mission lancée.**
