---
paths:
  - android/**
  - pubspec.yaml
  - RELEASE_*.md
  - docs/DISTRIBUTION_ANDROID.md
---

# Android / Play Store — invariants

Références : `docs/claude/INDEX.md` (prompts 62, 63, 68, 69, 81, 82), `docs/DISTRIBUTION_ANDROID.md`, `RELEASE_1.0.md`.

- `applicationId` = `com.azexpress.app`. `versionCode` / `versionName` dérivent de `pubspec.yaml` (`version: x.y.z+build`) ; Play Console exige un `versionCode` strictement croissant, jamais réutilisé.
- Signature release : `android/key.properties` + `android/app/release.keystore`, absents de git. Ne jamais les committer, lire ni afficher.
- Manifeste : `uses-feature` caméra / localisation / micro / bluetooth en `required="false"` ; `AD_ID` et `ACCESS_ADSERVICES_AD_ID` retirés (`tools:node="remove"`). Ne pas les réintroduire.
- `ACCESS_BACKGROUND_LOCATION` exige une déclaration Play Console dédiée. Clé Maps injectée via `${MAPS_API_KEY}` (`local.properties`).
- Conformité à maintenir : politique de confidentialité (FeexPay, Anthropic / AZ IA déclarés), page publique `/delete-account`, Data Safety.
- Builds : `flutter build appbundle --release` ; l'avertissement « strip debug symbols » vient de l'environnement local (cmdline-tools).
- Les `.aab` à la racine du dépôt sont des artefacts de distribution : ne pas les supprimer ni les committer sans demande.
