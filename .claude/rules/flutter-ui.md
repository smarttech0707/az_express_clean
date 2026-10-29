---
paths:
  - lib/theme/**
  - lib/widgets/**
  - lib/screens/**
  - lib/marketplace/**
  - lib/ekbine/**
---

# Flutter UI — règles pratiques

Références : `docs/claude/INDEX.md` (prompts 36, 43, 120, 121, 124-126, 136).

- Tokens : `AppColors` (orange `#F97316`, palette slate), `AppTypography` (Urbanist ; titre 20 SemiBold, texte 16 Medium, secondaire 14, petit 13), `AppLayout`, `AppRadius` (18/22/28), `AppShadow`. Pas de `GoogleFonts.inter` / `poppins` dans de nouveaux écrans.
- Mode sombre : `AppTheme.dark` couvre la chrome Material. Les écrans qui lisent `AppColors.xxx` en dur restent clairs : limite connue, ne pas « corriger » en transformant `AppColors` en accesseurs dynamiques sans décision.
- Composants partagés à réutiliser : `AppButton`, `AppCard`, `StatusBadge` / `AppStatus.fromRaw` (statuts `orders` uniquement : ne pas y forcer d'autres vocabulaires), `EmptyState`, `StreamErrorState`, `FadeSlideIn`, `SinglePhotoEditor`, `partner_account_sheet.dart`, `showLogoutConfirmDialog`, `showAccountDeletionRequestDialog`, `glass_kit.dart`.
- `ScaleButton` / `TapEffect` : le haptique passe par `AppHaptics` ; `HapticFeedback.vibrate()` est un choix délibéré de compatibilité matérielle.
- Accessibilité : `Semantics` ajouté partiellement ; tout nouveau bouton icône seule doit avoir `tooltip` ou `Semantics(label:)`. Le contraste blanc sur orange primaire ≈ 2,8:1 (sous AA) : décision de marque à trancher, ne pas changer seul.
- Images réseau : préférer `CachedNetworkImage` ; `Image.network` brut est une dette connue (~24 fichiers), à corriger au fil de l'eau.
- Listes : `.limit(N)` explicite. Ne pas ajouter `.limit()` à une requête dont le résultat est sommé côté client (totaux admin faussés).
- Aucune logique métier dans un `build()` ; ne pas lancer de requête réseau dans un `itemBuilder` (créer le `Future` dans `initState`).
- Photos / uploads : `imageQuality` et `maxWidth` appliqués ; chemins Storage et règles : voir `firestore-rules.md`.
