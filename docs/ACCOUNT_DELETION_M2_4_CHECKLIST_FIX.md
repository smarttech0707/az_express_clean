# Mission M2.4 — Correction de la ligne 91 de la checklist de suppression de compte

Seule la ligne 91 de `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` a été modifiée. Aucun build, aucun accès Firebase, aucune écriture dans `config/app_versions`, aucune règle modifiée, aucun déploiement, aucun nettoyage de cache. Aucun `git checkout/restore/reset/clean`, aucun stash, aucun commit ni push. T0 n'est ni défini ni activé.

## 1. Audit préalable

| Élément | Constat |
|---|---|
| Chemin exact | `D:\az_express_clean\docs\ACCOUNT_DELETION_RELEASE_CHECKLIST.md` (suivi par Git) |
| État Git | `M` (modifié localement, non commité) |
| Empreinte / taille / date avant | `8a130216a032b6577a39f148f805d9f2a15ae789` / 17 702 octets / 2026-11-06 18:32:09 UTC |
| Fins de ligne | LF (0 octet CR), identique à HEAD |
| Modifications locales préexistantes | **Un seul bloc : 12 lignes insérées aux lignes 111–122**, section « Corrections locales du 6 novembre 2026 (Mission 7E-64) — rien déployé » (anti-abus, journal, inventaire avant suppression Auth, AZ IA, pages légales, Hosting, tests). Cohérent avec le travail de suppression de compte |
| Position de la ligne 91 | Dans la partie **non modifiée** du fichier : identique à la ligne 91 de HEAD. Elle n'appartient pas au bloc modifié localement ; les deux zones ne se chevauchent pas |
| Contexte (lignes 86–95) | Étape 5 d'une procédure de déploiement coordonné : « Produire des versions mobiles dédiées à la validation, pointant explicitement vers cet environnement… » (l'étape 2 parle d'un « environnement de validation séparé ») |

Les modifications locales ne sont donc pas toutes liées à la ligne 91 : le bloc 111–122 est sans rapport et n'a pas été touché.

## 2. Point de vigilance découvert avant d'écrire

Remplacer simplement `flutter build appbundle --release` par `py scripts/build_mobile.py appbundle` aurait donné une consigne **inapplicable** : `scripts/build_mobile.py` exige `FIREBASE_PROJECT_ID == 'az-express-b0469'` (lignes 73–74, « Firebase project mismatch » sinon), alors que l'étape 5 vise un **environnement de validation séparé**. Le script centralisé est donc utilisable aujourd'hui pour les builds de production, pas pour cet environnement.

## 3. Modification réalisée (ligne 91 uniquement)

Les deux commandes directes sont remplacées par les scripts centralisés, et une phrase signale la limite ci-dessus. Le reste de la ligne est inchangé.

- Avant : `Android : \`flutter build appbundle --release\` … iOS : sur Mac, \`flutter build ipa --release\` …`
- Après : `Android : \`py scripts/build_mobile.py appbundle\` … iOS : sur Mac, \`python3 scripts/build_mobile.py ipa --build-number "$IOS_BUILD_NUMBER"\` …` suivi de : « Ces scripts imposent `APP_BUILD_NUMBER` (entier strictement positif, jamais de `flutter build` direct) mais n'acceptent aujourd'hui que le projet Firebase `az-express-b0469` : pour un environnement de validation séparé ils doivent d'abord être adaptés (décision requise) ; l'injection du numéro dans un AAB/IPA réel n'est pas vérifiée. »

## 4. Vérifications

- **Preuve que seule la ligne 91 a changé** : en remettant l'ancien texte de la ligne 91 dans le fichier actuel, on retrouve exactement l'empreinte d'avant (`8a130216a032b6577a39f148f805d9f2a15ae789`). Le diff contre HEAD ne montre plus que deux zones : ligne 91 (cette correction) et l'insertion 111–122 (préexistante, intacte).
- 122 lignes avant et après ; 0 octet CR ; aucun reformatage.
- Les commandes visent des scripts existants : `scripts/build_mobile.py` (cibles `appbundle` et `ipa`) ; `IOS_BUILD_NUMBER` est bien la variable utilisée par `codemagic.yaml`.
- Nouvelle empreinte : `f97ccad53b8e517fd0ecd1078643712468190bf9` ; taille 18 093 octets (+391) ; modifiée le 2026-11-11 20:33:51 UTC.
- **NON VÉRIFIÉE** : la présence de `APP_BUILD_NUMBER` dans un AAB/IPA réel (aucun build) ; l'adaptation du script à un environnement de validation (non existante).

## 5. Décision nécessaire

Pour l'étape 5 (builds visant l'environnement de validation) : adapter `build_mobile.py` pour accepter explicitement un projet de validation autorisé (modification de script, tests, garde-fou contre la production) ou fournir une autre procédure centralisée. Aucune adaptation faite ici.

## 6. État Git

| | Avant M2.4 | Après M2.4 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index | vide | vide |
| Stash | 0 | 0 |
| Fichiers suivis modifiés | 60 | 60 (la checklist était déjà modifiée) |
| Fichiers non suivis | 181 | 182 (ce rapport) |

Travaux M1, M2, M2.1, M2.2 et M2.3 préservés ; fichiers protégés inchangés.

**Arrêt : aucune autre mission lancée.**
