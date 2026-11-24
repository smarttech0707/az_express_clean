# M2.18 — Premier APK debug préproduction : arrêt avant compilation

Date : 2026-11-11. **Aucun build lancé.** Conclusion : **BUILD NON VALIDÉ** (précondition 1 non satisfaite).

## Constat

- `D:\AZExpress-secrets\preprod\google-services.json` n'existe pas (ni le dossier `D:\AZExpress-secrets`).
- La mission demande de placer le fichier fourni à cet emplacement. La création du fichier par l'outil d'écriture de Claude Code a été **refusée** par le classificateur de permissions du harnais (action jugée irréversible/sensible). Je n'ai pas contourné ce refus (aucun autre outil, aucune commande alternative).
- Contrôle 1 : ÉCHEC. `validate_preprod_gs.py` lancé sur ce chemin : erreur « fichier introuvable » (aucune valeur lue). Les contrôles 2 à 12 n'ont donc pas été exécutés : NON VÉRIFIÉ. Pas de redirection TEMP/TMP, pas de wrapper, pas de Gradle/Flutter.

## Actions réalisées

Lecture seule : test d'existence du chemin, état Git, exécution de `validate_preprod_gs.py` (échec de lecture). Aucun fichier du dépôt modifié, aucun secret écrit dans ce rapport.

## État Git

HEAD d65c8f0, index 0, stash 0, 62 modifiés ; non suivis 201 → 202 (ce rapport). Aucun commit/push/stash/reset/clean.

## Pour reprendre

Deux options (au choix du propriétaire) :
1. Créer vous-même `D:\AZExpress-secrets\preprod\google-services.json` (copie du fichier fourni) puis relancer M2.18 ;
2. Ajouter une règle de permission autorisant à Claude Code d'écrire ce fichier précis (dans les réglages Edit), puis relancer M2.18.

Reprise ensuite : contrôles 1 à 12 → redirection TEMP/TMP de session vers `D:\az-build-temp` → wrapper `-MapsDisabled` → vérifications de l'APK.

**STOP.**
