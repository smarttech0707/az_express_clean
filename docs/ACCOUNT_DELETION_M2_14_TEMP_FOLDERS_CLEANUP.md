# M2.14 — Inventaire et correction des dossiers temporaires `az-preprod-*`

Date : 2026-11-11. Aucun build, aucun Flutter/Gradle, aucun accès distant, `build_preprod.py` et le code de production non modifiés.

## 1. Inventaire (lecture seule)

Commande : `py <scratchpad>\inventory_m214.py` (script en lecture seule : ne suppose rien, n'affiche aucun contenu, ne supprime rien).
Racine inspectée : `C:\Users\User\AppData\Local\Temp` (résolue, vérifiée).

| Contrôle | Résultat sur les 63 dossiers |
|---|---|
| Situés directement dans le dossier temporaire attendu | 63 / 63 |
| Lien symbolique, jonction ou point d'analyse (dossier ou contenu) | **0** |
| Fichiers présents | uniquement `defines.json` (63) et `maps_test_key.txt` (43) ; aucun autre |
| `defines.json` strictement égal aux jeux de données fictifs des tests (`good_defines()`, avec ou sans `TEST_MAPS_API_KEY`) | 63 / 63 |
| `maps_test_key.txt` strictement égal à la fausse clé `TEST_KEY` des tests | 43 / 43 (0 vide) |
| Origine synthétique confirmée | **63 / 63** |
| Taille totale | 29 014 octets |
| Dates | 2026-11-11 21:40:26 → 22:32:26 (ces sessions) |

Aucun secret n'a été affiché : la comparaison est faite en mémoire (égalité avec les constantes des tests), seuls des booléens sont imprimés. 20 dossiers n'ont que `defines.json` (processus tué avant la création du fichier de clé), 43 ont aussi `maps_test_key.txt`.

Preuve d'origine : les trois tests qui tuent un sous-processus avec `os._exit` (`finally` jamais exécuté) sont les seuls producteurs possibles ; ils utilisaient le dossier temporaire système. Après correction, la suite complète ne crée plus aucun dossier (voir §3).

### Liste

| # | Dossier | Modifié | Octets | Contenu |
|---|---|---|---|---|
| 1 | `az-preprod-034nqiux` | 2026-11-11 22:27:28 | 478 | defines.json + maps_test_key.txt |
| 2 | `az-preprod-06olbdlf` | 2026-11-11 22:24:18 | 439 | defines.json |
| 3 | `az-preprod-1b0ef3h2` | 2026-11-11 22:32:19 | 439 | defines.json |
| 4 | `az-preprod-26hvzmve` | 2026-11-11 22:23:34 | 439 | defines.json |
| 5 | `az-preprod-3899xcg1` | 2026-11-11 22:32:23 | 478 | defines.json + maps_test_key.txt |
| 6 | `az-preprod-3pa7yotc` | 2026-11-11 22:27:22 | 478 | defines.json + maps_test_key.txt |
| 7 | `az-preprod-43xyhot_` | 2026-11-11 22:22:40 | 439 | defines.json |
| 8 | `az-preprod-4t_jao28` | 2026-11-11 22:27:26 | 439 | defines.json |
| 9 | `az-preprod-5m26ohwl` | 2026-11-11 22:30:01 | 439 | defines.json |
| 10 | `az-preprod-6ku4305i` | 2026-11-11 22:11:29 | 478 | defines.json + maps_test_key.txt |
| 11 | `az-preprod-6yqdys1_` | 2026-11-11 22:23:38 | 478 | defines.json + maps_test_key.txt |
| 12 | `az-preprod-758wd_js` | 2026-11-11 22:28:21 | 478 | defines.json + maps_test_key.txt |
| 13 | `az-preprod-7jbofqhq` | 2026-11-11 22:23:35 | 478 | defines.json + maps_test_key.txt |
| 14 | `az-preprod-7r8ijmxn` | 2026-11-11 22:29:03 | 478 | defines.json + maps_test_key.txt |
| 15 | `az-preprod-8477y4od` | 2026-11-11 22:29:06 | 478 | defines.json + maps_test_key.txt |
| 16 | `az-preprod-86b4ifgf` | 2026-11-11 22:28:20 | 439 | defines.json |
| 17 | `az-preprod-889zjyhz` | 2026-11-11 21:52:51 | 478 | defines.json + maps_test_key.txt |
| 18 | `az-preprod-8l3bh2bn` | 2026-11-11 22:31:27 | 439 | defines.json |
| 19 | `az-preprod-907e7zk3` | 2026-11-11 22:31:51 | 478 | defines.json + maps_test_key.txt |
| 20 | `az-preprod-9odqmaeq` | 2026-11-11 22:22:58 | 478 | defines.json + maps_test_key.txt |
| 21 | `az-preprod-ah1o6rxu` | 2026-11-11 22:27:27 | 439 | defines.json |
| 22 | `az-preprod-c30noiu1` | 2026-11-11 22:22:41 | 478 | defines.json + maps_test_key.txt |
| 23 | `az-preprod-cgaddxdk` | 2026-11-11 21:52:39 | 478 | defines.json + maps_test_key.txt |
| 24 | `az-preprod-cuftlrbf` | 2026-11-11 21:40:26 | 375 | defines.json |
| 25 | `az-preprod-dd2aykq2` | 2026-11-11 21:42:25 | 375 | defines.json |
| 26 | `az-preprod-e2s5ie0q` | 2026-11-11 22:31:50 | 478 | defines.json + maps_test_key.txt |
| 27 | `az-preprod-eb5utstq` | 2026-11-11 21:40:50 | 375 | defines.json |
| 28 | `az-preprod-ejm8ahvr` | 2026-11-11 22:24:14 | 478 | defines.json + maps_test_key.txt |
| 29 | `az-preprod-favt73ca` | 2026-11-11 22:22:44 | 478 | defines.json + maps_test_key.txt |
| 30 | `az-preprod-fl1zq_5p` | 2026-11-11 22:24:11 | 439 | defines.json |
| 31 | `az-preprod-fn9ypebh` | 2026-11-11 22:32:26 | 439 | defines.json |
| 32 | `az-preprod-gpl8r56s` | 2026-11-11 22:29:05 | 478 | defines.json + maps_test_key.txt |
| 33 | `az-preprod-h3t1vxuv` | 2026-11-11 21:41:01 | 375 | defines.json |
| 34 | `az-preprod-h_lx5igi` | 2026-11-11 22:22:54 | 439 | defines.json |
| 35 | `az-preprod-hmkslyrm` | 2026-11-11 22:24:22 | 478 | defines.json + maps_test_key.txt |
| 36 | `az-preprod-j190bqu3` | 2026-11-11 22:28:25 | 478 | defines.json + maps_test_key.txt |
| 37 | `az-preprod-j3fbzcof` | 2026-11-11 22:32:20 | 478 | defines.json + maps_test_key.txt |
| 38 | `az-preprod-jbe71_4q` | 2026-11-11 22:29:02 | 439 | defines.json |
| 39 | `az-preprod-jvr4g3gb` | 2026-11-11 22:13:20 | 478 | defines.json + maps_test_key.txt |
| 40 | `az-preprod-mqs0z64l` | 2026-11-11 22:24:23 | 478 | defines.json + maps_test_key.txt |
| 41 | `az-preprod-na13pqtc` | 2026-11-11 22:24:15 | 478 | defines.json + maps_test_key.txt |
| 42 | `az-preprod-nbq39evt` | 2026-11-11 22:24:12 | 478 | defines.json + maps_test_key.txt |
| 43 | `az-preprod-nyh9oxcm` | 2026-11-11 22:32:15 | 478 | defines.json + maps_test_key.txt |
| 44 | `az-preprod-oj7rc007` | 2026-11-11 22:22:45 | 478 | defines.json + maps_test_key.txt |
| 45 | `az-preprod-p4jon_f2` | 2026-11-11 22:31:43 | 478 | defines.json + maps_test_key.txt |
| 46 | `az-preprod-q2o1_qe5` | 2026-11-11 22:24:19 | 478 | defines.json + maps_test_key.txt |
| 47 | `az-preprod-q8rn5yxv` | 2026-11-11 22:23:37 | 478 | defines.json + maps_test_key.txt |
| 48 | `az-preprod-qhum9jg5` | 2026-11-11 22:22:55 | 478 | defines.json + maps_test_key.txt |
| 49 | `az-preprod-qjrku6qg` | 2026-11-11 22:28:23 | 478 | defines.json + maps_test_key.txt |
| 50 | `az-preprod-qtjo7dip` | 2026-11-11 22:31:48 | 478 | defines.json + maps_test_key.txt |
| 51 | `az-preprod-qx5wgsud` | 2026-11-11 22:22:59 | 478 | defines.json + maps_test_key.txt |
| 52 | `az-preprod-r8y2b2zp` | 2026-11-11 21:52:20 | 478 | defines.json + maps_test_key.txt |
| 53 | `az-preprod-rejh54_h` | 2026-11-11 21:40:36 | 375 | defines.json |
| 54 | `az-preprod-rrxafzpy` | 2026-11-11 22:24:07 | 478 | defines.json + maps_test_key.txt |
| 55 | `az-preprod-s6nw1nj7` | 2026-11-11 22:28:58 | 478 | defines.json + maps_test_key.txt |
| 56 | `az-preprod-u0y2azuo` | 2026-11-11 21:52:24 | 478 | defines.json + maps_test_key.txt |
| 57 | `az-preprod-u2rs2bk6` | 2026-11-11 22:31:54 | 439 | defines.json |
| 58 | `az-preprod-u6z29l7o` | 2026-11-11 22:28:16 | 478 | defines.json + maps_test_key.txt |
| 59 | `az-preprod-v1qy5mlw` | 2026-11-11 22:27:26 | 478 | defines.json + maps_test_key.txt |
| 60 | `az-preprod-w76gwl5y` | 2026-11-11 21:54:06 | 478 | defines.json + maps_test_key.txt |
| 61 | `az-preprod-y5m8t315` | 2026-11-11 22:31:47 | 439 | defines.json |
| 62 | `az-preprod-ytlxbapz` | 2026-11-11 22:27:29 | 478 | defines.json + maps_test_key.txt |
| 63 | `az-preprod-zee15dkh` | 2026-11-11 22:32:22 | 478 | defines.json + maps_test_key.txt |

## 2. Correction des tests (seuls fichiers de tests modifiés)

Cause : trois tests lancent un enfant Python tué par `os._exit` ; son `TemporaryDirectory` ne peut pas être nettoyé et il se trouvait dans le dossier temporaire système partagé.

| Fichier | Changement |
|---|---|
| `scripts/test_build_preprod.py` | `Base` : instantané des dossiers `az-preprod-*` du temp système en `setUp` ; `killed_child_env()` (TEMP/TMP/TMPDIR de l'enfant = sous-dossier de l'arbre temporaire du test) ; `assert_no_scratch_left()` exécuté après le nettoyage du test (dossier de test supprimé, aucun nouveau `az-preprod-*` dans le temp système) ; test de kill du moteur : `env=self.killed_child_env()` |
| `scripts/test_preprod_m211.py` | `kill_child` : `env=self.killed_child_env()` |
| `scripts/test_preprod_m212.py` | kill entre écriture partielle et renommage : `env=self.killed_child_env()` |

Garanties : le dossier abandonné par l'enfant tué vit dans l'arbre du test, supprimé par `TemporaryDirectory.cleanup` (enregistré avant, donc exécuté même après un échec) ; la vérification s'applique à tous les tests héritant de `Base` (échecs simulés compris) ; les tests ne suppriment jamais un dossier préexistant (ils ne suppriment que leur propre arbre ; le contrôle compare uniquement les dossiers apparus pendant le test).

## 3. Résultats

- Suite complète `py -m unittest discover -s scripts -p "test_*.py"` : **188 tests OK** (avant et après correction).
- Temp système avant / après la suite : **identique** (63 dossiers, aucun ajouté, aucun retiré).
- Contrôle de mutation : en rétablissant temporairement l'ancien environnement (sans fichier modifié), le test de kill **échoue** avec « az-preprod-* scratch folders left in the system temp folder » : la détection fonctionne. Ce contrôle a créé 1 dossier (`az-preprod-5razplky`, mon propre dossier, contenu fictif), supprimé aussitôt après vérification ; les 63 préexistants n'ont pas été touchés (comparaison avant/après de la liste identique).
- Moteur `scripts/build_preprod.py` : non modifié (dernière modification 22:27:11, M2.12).

## 4. Dossiers préexistants

**Aucun des 63 dossiers n'a été supprimé** : liste avant/après identique.
Les 63 dossiers ci-dessus ont une origine synthétique confirmée ; leur suppression nécessite une **autorisation distincte** (non demandée ici). Méthode proposée : suppression par liste de noms exacte, après revérification de l'absence de redirection.

## 5. État Git

| | Avant | Après |
|---|---|---|
| HEAD | d65c8f0 | d65c8f0 |
| Index / Stash | 0 / 0 | 0 / 0 |
| Modifiés | 62 | 62 |
| Non suivis (porcelain) | 197 | 198 (+ ce rapport) |

Les trois fichiers de tests sont non suivis (nouveaux depuis M2.6) : leur modification n'apparaît pas comme « modifié ». Hachages inchangés : passwordReset 26975f60, index a9ba2c0d, firestore.rules 5341bfd6, storage.rules f3b5b608, build.gradle.kts 29bd8394. Aucun commit/push/stash/reset/clean.

## 6. Risques résiduels

- 63 dossiers (29 Ko, fictifs) restent dans le temp système jusqu'à autorisation de suppression.
- `assert_no_scratch_left` compare le temp système : un build préprod réel lancé en parallèle pendant les tests pourrait provoquer un faux échec (sans impact sur les données).
- Un arrêt brutal des tests eux-mêmes (kill du processus de test) laisserait toujours des dossiers : cas non couvert par un test.
- Les tests antérieurs à M2.6 (`test_app_build_number`, `test_ios_build_guard`, etc.) utilisent `TemporaryDirectory` en `with` : non en cause, non modifiés.

## 7. Conclusion : **VALIDÉ**

**STOP** — suppression des 63 dossiers : en attente d'une autorisation écrite distincte.
