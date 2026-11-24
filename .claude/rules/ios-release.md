---
paths:
  - ios/**
  - codemagic*
  - docs/DISTRIBUTION_*.md
---

# iOS / TestFlight — points d'attention

Références : `docs/claude/INDEX.md` (prompt 64). L'archive iOS date de juillet 2026 : l'état récent (builds TestFlight 12/13, Codemagic) est plus avancé — voir `docs/claude/known-issues.md` et `git log -- ios`.

- `flutter build ios` est impossible sous Windows (macOS / Codemagic requis).
- `Info.plist` doit contenir les usage descriptions (caméra, photothèque, localisation, micro, reconnaissance vocale) : leur absence fait **planter** l'app iOS, pas seulement refuser la review. `UIBackgroundModes` (location, remote-notification) déclarés.
- Le bundle ID cible est `com.azexpress.app` (aligné Android et Firebase). Vérifier l'état réel dans `ios/Runner.xcodeproj` avant d'affirmer quoi que ce soit.
- App Check iOS : `AppleProvider.deviceCheck` en release (App Attest exige iOS 14+).
- Ne jamais committer ni afficher `GoogleService-Info.plist`, certificats, profils de provisionnement ni clés App Store Connect.
