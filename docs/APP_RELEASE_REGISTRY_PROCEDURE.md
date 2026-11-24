# Registre des builds publiés — `config/app_release_registry` (M2.3, politique formalisée en M2.4)

**État : préparation locale. Rien n'a été écrit dans Firebase (préproduction ou production), rien n'est déployé.**

## 1. Décisions de politique (propriétaire AZ Express, formalisées en M2.4)
1. **Android : Google Play Store uniquement.** Le registre `android` ne reflète que le dernier build disponible sur Google Play.
2. **iOS : Apple App Store uniquement.** Le registre `ios` ne reflète que le dernier build « Prêt à la vente » sur l'App Store (TestFlight exclu).
3. **APK distribué directement : canal indépendant**, exclu du registre. `web/distribution/latest.json` (versionCode 11 au 2026-10-14) décrit ce canal et ne doit jamais alimenter le registre `android`. Si une politique de version minimale devait un jour concerner l'APK direct, ce serait un mécanisme distinct, à décider séparément.
4. **Responsable de saisie** : le propriétaire AZ Express, ou un super-administrateur expressément autorisé par lui (par écrit). Pas de sous-administrateur, pas d'automate, pas d'AZ IA.
5. **Seconde vérification** par une autre personne : recommandée dès que possible (voir §5).

## 2. À quoi sert le registre
`setAppVersionsConfigCF` (M2.2) refuse de définir ou relever un `minBuild` tant que le dernier build publié de chaque plateforme concernée n'est pas enregistré et vérifié, et refuse un `minBuild` supérieur à ce build. Le dépôt ne peut pas connaître ce numéro : un humain le relève dans la console officielle et le saisit avec l'outil. Il n'est jamais déduit de `pubspec.yaml`, de `latest.json`, d'un build local ni d'une valeur précédente.

Format (`config/app_release_registry`, écriture réservée à l'Admin SDK, lecture super-administrateur) :
```
android: { latestBuild, source: "google-play-console", sourceDetail, evidence, secondVerifier|null, verifiedAt, enteredBy }
ios:     { latestBuild, source: "app-store-connect",   sourceDetail, evidence, secondVerifier|null, verifiedAt, enteredBy }
updatedAt, updatedBy: "tool:appReleaseRegistry"
```
La fonction lit `latestBuild`, `source` et `verifiedAt` ; le reste sert à l'audit.

## 3. Sources officielles acceptées (valeur fermée dans l'outil)
| Plateforme | `--source` accepté | Console |
|---|---|---|
| android | `google-play-console` | Google Play Console |
| ios | `app-store-connect` | App Store Connect |

Toute autre valeur est refusée (`UNAUTHORIZED_SOURCE`) : APK direct, `latest.json`, TestFlight, Firebase App Distribution, test interne, texte libre, source de l'autre plateforme. Le texte libre (piste, état, version) va dans `--detail` et n'influence jamais l'autorisation.

## 4. Informations à relever et preuves à conserver
**Android — Google Play Console** : application AZ Express → piste **Production** (ou la piste réellement ouverte aux utilisateurs) → Versions. Prendre la version à l'état **Disponible** (ni brouillon, ni en examen, ni déploiement arrêté ; noter le pourcentage si déploiement progressif). Relever le **code de version** (`versionCode`) du bundle. Le numéro à saisir est ce code, pas le nom de version (`1.0.10`).

**iOS — App Store Connect** : AZ Express → App Store → version **Prête à la vente**. Relever le **numéro de build** (`CFBundleVersion`) rattaché à cette version. Le dernier build iOS publié est inconnu du dépôt (`docs/PUBLICATION_1_0_10_PLAN.md`) : ne jamais supposer qu'il égale le build Android.

**Preuves** (dossier daté, hors dépôt public, sans jeton ni clé visible) : capture de la console (application, piste/version, état, numéro de build, date et heure), sortie de la simulation puis de l'écriture, nom de l'opérateur et du second vérificateur, référence `--evidence`, identifiant de l'entrée `audit_logs`.

## 5. Procédure de saisie et double vérification
Depuis `functions/` :
```
# 1) Simulation (défaut) : aucun accès réseau, rien n'écrit
node scripts/appReleaseRegistry.js --project az-express-b0469 --platform android --build <N> \
  --source google-play-console --detail "piste production, Disponible, versionCode" \
  --verified-at <ISO 8601 avec fuseau> --evidence "<référence capture>" --operator "<nom>" --second-verifier "<autre personne>"
# 2) Écriture : mêmes arguments + --apply --confirm az-express-b0469:android:<N>
```
1. L'opérateur relève le build dans la console officielle, fait la capture, lance la simulation.
2. Le second vérificateur (autre personne) compare, sur la console, le build, la piste/l'état et la date avec la simulation, puis donne son accord ; son nom est passé par `--second-verifier` (refusé s'il est identique à l'opérateur).
3. L'opérateur lance `--apply --confirm …`. La confirmation est recopiée de la simulation.
4. Sans seconde personne disponible : la simulation affiche « aucune seconde vérification déclarée » et `secondVerifier` est `null` dans le registre et l'audit. Le consigner comme risque accepté et refaire la vérification dès qu'une seconde personne est disponible.

Garde-fous techniques : projet explicite (`az-express-b0469` ou `demo-*` émulateur, tout autre ID dont l'ancien `az-express-clean` refusé) ; `demo-*` exige `FIRESTORE_EMULATOR_HOST` ; projet réel refusé si un émulateur est actif ; aucun champ par défaut ; build entier strict 1..2 100 000 000 ; `verifiedAt` avec fuseau, ni futur ni > 30 jours ; baisse de build refusée ; l'outil n'écrit jamais `enforce` ; chaque écriture ajoute une entrée `audit_logs` (`app_release_registry_update`).

## 6. Si un numéro de build ne peut pas être vérifié
Ne **rien saisir**. Ne pas estimer, ne pas reprendre `pubspec.yaml`, `latest.json`, un ancien registre, un build TestFlight ou local. Conséquence voulue : `setAppVersionsConfigCF` continue de refuser tout `minBuild` défini ou relevé pour cette plateforme (`PUBLISHED_BUILD_UNVERIFIED`) ; abaisser ou retirer une contrainte reste possible. Consigner la raison (accès console perdu, version en examen, état ambigu), puis réessayer quand l'accès ou l'état est clair. Un registre périmé est sûr ; un registre en avance sur la réalité ne l'est pas.

## 7. Mise à jour
À refaire après chaque publication ou retrait d'une version sur un store, par la même procédure.

## 8. Limites
Un humain reste la source de vérité ; l'outil contrôle la forme et la source déclarée, pas la réalité du store. Le registre n'a d'effet qu'une fois `setAppVersionsConfigCF` et les règles M2.2 déployés (non autorisé à ce jour). Les anciens binaires (build 0) ne sont pas bloquables. La saisie réelle de ce registre n'a pas eu lieu.
