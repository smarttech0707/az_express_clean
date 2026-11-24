# M2.18 (reprise) — Fichier Firebase préproduction introuvable

Date : 2026-11-11. **Aucun build lancé.** Conclusion : **BUILD NON VALIDÉ** (contrôle 1 en échec).

## Constat

- `D:\AZExpress-secrets\preprod\google-services.json` : **absent**. Le dossier `D:\AZExpress-secrets` n'existe pas non plus.
- Recherche d'un dossier au nom proche (`*secret*`, `AZE*`) à la racine de D: et d'un `google-services*.json` (profondeur ≤ 3, hors dépôt et `D:\cie`) : aucun résultat.
- `validate_preprod_gs.py` sur ce chemin : fichier introuvable (aucune valeur lue). Contrôles 2 à 12 : NON VÉRIFIÉ.
- Aucun fichier créé, copié ni modifié pour contourner les permissions. Pas de redirection TEMP/TMP, pas de wrapper, pas de Flutter/Gradle.

Hypothèses à vérifier côté propriétaire : le fichier a été placé sur un autre lecteur ou un autre nom de dossier ; la session de Claude Code ne voit pas le même D: ; la création n'a pas abouti.

## État Git

HEAD d65c8f0, index 0, stash 0, 62 modifiés ; non suivis 202 → 203 (ce rapport). Aucun commit/push/stash/reset/clean.

**STOP.** Indiquer le chemin réel du fichier (ou confirmer sa présence) pour relancer M2.18.
