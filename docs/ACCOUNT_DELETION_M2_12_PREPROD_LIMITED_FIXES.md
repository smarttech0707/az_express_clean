# M2.12 — Corrections limitées du build préproduction

Date : 2026-11-11. Périmètre autorisé : `scripts/build_preprod.py` uniquement (plus ses tests).
Aucun build réel, aucun Gradle, aucun accès Firebase, aucune vraie clé Maps.

## 1. Fichiers

| Fichier | Statut |
|---|---|
| `scripts/build_preprod.py` | modifié (non suivi par Git) : 3 corrections |
| `scripts/test_preprod_m212.py` | nouveau : 24 tests |
| `scripts/test_preprod_m211.py`, `test_build_preprod_maps.py`, `test_gradle_maps_review.py` | tests adaptés au nouveau comportement (voir §4) |
| `docs/ACCOUNT_DELETION_M2_12_PREPROD_LIMITED_FIXES.md` | ce rapport |

Non touchés : `build.gradle.kts` (blob 29bd8394), `build_mobile.py`, `run.ps1`, configs Firebase, fichiers protégés, checklist de suppression de compte (f97ccad5).

## 2. Corrections

1. **Neutralisation d'un `azTestMapsKeyFile` ambiant.** Le fichier de clé temporaire est désormais toujours créé et `--android-project-arg=azTestMapsKeyFile=<chemin>` toujours passé. En `--maps-disabled`, le fichier est **vide** : la propriété en ligne de commande l'emporte sur gradle.properties/environnement, Gradle lit `""`. `azTestMapsKey=` (vide) reste toujours passé.
2. **`state.json` atomique.** Nouvelle `write_state_atomically` : écriture dans `state.json.az-partial` (mode `x`), flush + fsync, puis `os.replace`. En cas d'erreur ou d'interruption propre, le partiel est supprimé. Après un arrêt brutal, il reste `state.json.az-partial` et **jamais** un `state.json` vide. `recovery_state()` signale ce cas (« state write was interrupted ») et le build suivant est refusé avec « Recovery required », sans rien supprimer.
3. **Emplacement ASCII.** Nouvelle `ascii_scratch_parent()` : temp système si ASCII ; sinon `<dépôt>/build` (ignoré par Git) si ce chemin est ASCII ; sinon refus explicite avant toute modification de fichier. Le dossier temporaire est supprimé dans tous les cas.

## 3. Diff exact

Diff `diff -u` de `build_preprod.py` (état avant M2.12 → état actuel), 105 lignes, copie : `C:\Users\User\AppData\Local\Temp\claude\d--az-express-clean\c579b050-5748-4442-a523-d168d26fdffb\scratchpad\m212.diff`. Résumé des hunks :

- `recovery_state()` : prise en compte de `state.json.az-partial`.
- + `ascii_scratch_parent()` et + `write_state_atomically()`.
- `build()` : `scratch_parent = ascii_scratch_parent()` avant le `try` ; `TemporaryDirectory(..., dir=scratch_parent)` ; `write_state_atomically(...)` à la place de `state.open('x')` + `json.dump` ; création du fichier de clé et ajout de `azTestMapsKeyFile` sans condition (contenu `test_key or ''`).

## 4. Tests

- Cible : `py -m unittest scripts.test_preprod_m212` → **24 tests OK**. Couvre : fichier vide en mode désactivé, valeur ambiante neutralisée (modèle `new_value`) et contrôle négatif de l'ancien comportement, absence de toute clé dans argv/defines/logs, mode clé inchangé, nettoyage après succès et échec, état atomique (échec d'écriture, échec du rename, interruption avec état existant intact, partiel résiduel bloquant, kill réel par sous-processus entre l'écriture et le rename), emplacement ASCII (temp ASCII, temp accentué avec repli, mode désactivé, nettoyage sur échec, refus sans effet de bord), garde de périmètre (blob de `build.gradle.kts`).
- Suite complète : `py -m unittest discover -s scripts -p "test_*.py"` → **188 tests OK** (164 avant les nouveaux tests), exécutée une seule fois à la fois, sans concurrence sur les émulateurs.
- Tests existants adaptés : `test_preprod_m211` (temp accentué + dépôt accentué → refus ASCII ; échec d'écriture de l'état → ni `state.json` vide ni partiel ; kill entre sauvegarde et état → partiel identifiable ; kill de restauration sur le 3ᵉ `os.replace`), `test_build_preprod_maps` et `test_gradle_maps_review` (fichier de clé vide en mode désactivé).
- Récupération après interruption : le kill réel laisse `maps_key.dart` intact, la sauvegarde présente et le build suivant refuse avec un état identifiable.
- Le wrapper `-CheckOnly -MapsDisabled` n'a **pas** été relancé dans cette mission (les tests du wrapper de la suite passent) : NON VÉRIFIÉ en conditions réelles.

## 5. Limites restantes

- Le Kotlin de `build.gradle.kts` n'a jamais été compilé : NON VÉRIFIÉ. La lecture du fichier vide (`readText().trim()` → `""`) est établie par le modèle de décision, pas par Gradle.
- Le chemin du fichier de clé à travers Flutter/Gradle sur Windows (y compris ASCII) : NON VÉRIFIÉ sans build réel.
- Une clé de test (mode clé) peut rester dans le cache de build Gradle (`~/.gradle/caches/build-cache-1`) : risque inchangé, évité par `-MapsDisabled`.
- Un arrêt brutal après la sauvegarde mais avant le rename de l'état laisse un état « incomplet » : refus sûr, récupération manuelle (la procédure M2.11 s'applique, `maps_key.dart` n'a pas encore été remplacé à ce stade).
- Un dossier `build/az-preprod-recovery` vide peut subsister après un échec de vérification de sauvegarde (inoffensif).

## 6. État Git

| | Avant | Après |
|---|---|---|
| HEAD | d65c8f0 | d65c8f0 |
| Index (fichiers indexés) | 0 | 0 |
| Stash | 0 | 0 |
| Modifiés | 62 | 62 |
| Non suivis (`git status --porcelain`, dossiers regroupés) | 194 | 196 (+ test M2.12, + ce rapport) |

Hachages protégés inchangés : passwordReset 26975f60, index a9ba2c0d, firestore.rules 5341bfd6, storage.rules f3b5b608, feexpayPayments 232dbcea, orderRefunds d985269a, build.gradle.kts 29bd8394, checklist f97ccad5.
Aucun commit, push, stash, reset, clean ni changement d'index. Aucun build, déploiement ni contact Firebase.

**STOP** — en attente d'une autorisation écrite pour la mission suivante.
