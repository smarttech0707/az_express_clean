# M2.16 — Premier APK debug préproduction : arrêt avant compilation

Date : 2026-11-11. **Aucun build lancé** (ni Flutter, ni Gradle, ni wrapper). Conclusion : **BUILD NON VALIDÉ** (précondition 1 non satisfaite).

## Contrôles préalables

| # | Contrôle | Résultat |
|---|---|---|
| 1 | `google-services.json` de préproduction présent à l'emplacement attendu | **ÉCHEC** : aucun fichier de préproduction trouvé |
| 2–4 | `project_id` `az-express-preprod`, numéro `306761725053`, package `com.azexpress.app.test` | NON VÉRIFIÉ (pas de fichier) |
| 5–7 | Cohérence Dart/Android, exclusion de la production, neutralisation Maps | NON VÉRIFIÉ en conditions réelles (couvert par les tests M2.12/M2.13, mais le wrapper ne peut pas être lancé sans le fichier natif) |
| 8 | Espace disque | **LIMITE** : C: = 3,7 Go libres (estimation M2.10 : ~3,7 Go nécessaires, marge nulle) ; D: = 105,5 Go. Flutter (`C:\flutter\bin\flutter.bat`) et Java (JDK 21) présents. Réseau/dépendances : non testés |

## Recherche du fichier

Recherche locale (dépôt, `Downloads`, `Desktop`, `Documents`, `D:\`, profondeur ≤ 5) des `google-services*.json`. Trouvés :
- `D:\az_express_clean\android\app\google-services.json` et sa copie `C:\Users\User\Desktop\az_express_clean\android\app\google-services.json` : lus uniquement pour des booléens (aucune valeur affichée) → **projet de production** ; ni préprod, ni numéro attendu, ni package `.test`. Inutilisables, volontairement non utilisés (le moteur les refuse de toute façon).
- `D:\az_express_clean\.scratch_shots\google-services-current*.json` : dossier à ne pas toucher (règle projet) ; non ouverts. `D:\cie\...` : autre projet, non ouvert.
- `android/app/src/debug/` ne contient que `AndroidManifest.xml` (aucun fichier natif posé).

Je n'ai ni utilisé le fichier synthétique de M2.13 (il ne permettrait pas une application réelle liée à Firebase préprod et falsifierait la validation), ni contourné une garde.

## Actions et commandes

Lecture seule : recherche de fichiers, lecture de booléens sur deux fichiers de production, `Get-PSDrive`. Aucun fichier du dépôt modifié.

## État Git

HEAD d65c8f0, index 0, stash 0, 62 modifiés ; non suivis 199 → 200 (ce rapport). Hachages protégés inchangés (aucun fichier touché). Aucun commit/push/stash/reset/clean ; `build/` non touché.

## Pour débloquer (décisions du propriétaire)

1. Télécharger depuis la console Firebase `az-express-preprod` le `google-services.json` de l'app Android `com.azexpress.app.test`, le placer **hors du dépôt** et m'indiquer son chemin exact (ou autoriser un emplacement précis).
2. Libérer de l'espace sur C: (ou accepter le risque de 3,7 Go libres) ; le cache Gradle est sur C:.
3. Confirmer que le numéro de projet `306761725053` correspond bien à la console (jamais vérifié).

Dès le fichier disponible : relancer la mission avec le wrapper `-MapsDisabled`, avec les mêmes contrôles.

**STOP.**
