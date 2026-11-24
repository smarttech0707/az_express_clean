# M2.15 — Suppression des 63 dossiers temporaires `az-preprod-*`

Date : 2026-11-11. Périmètre : exactement les 63 dossiers listés dans `ACCOUNT_DELETION_M2_14_TEMP_FOLDERS_CLEANUP.md`, dans `C:\Users\User\AppData\Local\Temp`.

## Méthode

Script `delete_m215.py` (scratchpad), liste lue depuis le rapport M2.14 (63 noms uniques). Pour **chaque** dossier, avant suppression :
1. nom présent dans la liste ;
2. chemin canonique directement dans le temp (`realpath` identique, parent = temp) ;
3. aucun lien symbolique/jonction/point d'analyse (dossier et contenu) ;
4. contenu limité à `defines.json` et `maps_test_key.txt`, égaux aux constantes synthétiques des tests (comparaison en mémoire, rien d'affiché) ;
5. tout écart → refus.

Suppression : fichiers supprimés un par un puis `rmdir` du dossier (aucune suppression récursive, aucun motif global, dossier parent jamais touché).

## Résultats

| | |
|---|---|
| Dossiers listés | 63 |
| **Supprimés** | **63** |
| Refus | 0 |
| Déjà absents | 0 |
| Dossiers listés encore présents | 0 |
| Entrées du temp avant / après | 850 / 787 (écart = 63) |
| Entrées retirées == ensemble supprimé | oui (aucune autre entrée du temp supprimée) |
| `az-preprod-*` hors liste (laissés intacts) | 0 |
| Entrées apparues pendant l'opération | 0 |

Aucune fausse clé n'est reproduite dans ce rapport.

## Git

HEAD d65c8f0, index 0, stash 0, 62 modifiés ; non suivis 198 → 199 (ce rapport). Aucun fichier du dépôt modifié, aucun build, accès Firebase, déploiement, commit/push/stash/reset/clean.

## Conclusion : **VALIDÉ**

**STOP** — en attente d'une autorisation écrite pour la mission suivante.
