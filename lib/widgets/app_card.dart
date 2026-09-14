import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'glass_kit.dart';

/// Master Prompt 126 (Partie 8) puis LOT 2 Premium V1 — construites sur les
/// cartes déjà existantes (`GlassCard`/`PremiumCard`, Master Prompt 120)
/// plutôt que réécrites : "Standard"/"Elevated"/"Glass"/"Premium"
/// délèguent directement, "Information"/"Warning"/"Error"/"Success" sont
/// des `PremiumCard` teintées de la couleur sémantique correspondante —
/// pas une 4ᵉ implémentation de carte, juste un jeu de couleurs différent
/// sur le même composant. `elevated` (LOT 2) est la seule addition réelle :
/// surface élevée + léger dégradé 2 tons + `AppShadow.glow()`, jamais de
/// `BackdropFilter`.
enum AppCardVariant {
  standard,
  elevated,
  glass,
  premium,
  info,
  warning,
  error,
  success,
}

/// Type sémantique pour [AppCard.semantic] — évite de répéter les 4 noms
/// de variantes `AppCardVariant` déjà utilisés en interne.
enum AppCardSemanticType { info, warning, error, success }

class AppCard extends StatelessWidget {
  final Widget child;
  final AppCardVariant variant;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final String? semanticLabel;

  const AppCard({
    super.key,
    required this.child,
    this.variant = AppCardVariant.standard,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.semanticLabel,
  });

  /// Carte premium par défaut (LOT 2) : surface, bordure 1px, rayon
  /// `premiumXl` (24), `AppShadow.card`.
  const AppCard.standard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.semanticLabel,
  }) : variant = AppCardVariant.standard;

  /// Carte premium mise en avant (LOT 2) : `surfaceElevated`, léger
  /// dégradé 2 tons, `AppShadow.glow()` — jamais de `BackdropFilter`.
  const AppCard.elevated({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.semanticLabel,
  }) : variant = AppCardVariant.elevated;

  /// Carte teintée sémantique (info/warning/error/success) — un seul point
  /// d'entrée nommé au lieu de 4 valeurs d'enum à retenir séparément.
  AppCard.semantic({
    super.key,
    required this.child,
    required AppCardSemanticType type,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.semanticLabel,
  }) : variant = switch (type) {
          AppCardSemanticType.info => AppCardVariant.info,
          AppCardSemanticType.warning => AppCardVariant.warning,
          AppCardSemanticType.error => AppCardVariant.error,
          AppCardSemanticType.success => AppCardVariant.success,
        };

  @override
  Widget build(BuildContext context) {
    switch (variant) {
      case AppCardVariant.standard:
        return _standard(context);
      case AppCardVariant.elevated:
        return _elevated(context);
      case AppCardVariant.glass:
        return GlassCard(
          padding: padding,
          margin: margin,
          onTap: onTap,
          semanticLabel: semanticLabel,
          child: child,
        );
      case AppCardVariant.premium:
        return PremiumCard(
          padding: padding,
          margin: margin,
          onTap: onTap,
          semanticLabel: semanticLabel,
          shadows: AppShadow.lg,
          child: child,
        );
      case AppCardVariant.info:
        return _tinted(context, AppColors.info, AppColors.blueBg);
      case AppCardVariant.warning:
        return _tinted(context, AppColors.warning, AppColors.warningBg);
      case AppCardVariant.error:
        return _tinted(context, AppColors.error, AppColors.redBg);
      case AppCardVariant.success:
        return _tinted(context, AppColors.success, AppColors.greenBg);
    }
  }

  /// LOT 2 — brief : "Standard : surface, border 1px, radius premiumXl,
  /// AppShadow.card".
  Widget _standard(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return PremiumCard(
      padding: padding,
      margin: margin,
      onTap: onTap,
      semanticLabel: semanticLabel,
      color: AppColors.premiumSurface(brightness),
      borderRadius: AppRadius.premiumXlR,
      border: Border.all(
        color: AppColors.premiumBorder(brightness),
        width: 1,
      ),
      shadows: AppShadow.card,
      child: child,
    );
  }

  /// LOT 2 — brief : "Elevated : surfaceElevated, léger gradient 2 tons,
  /// AppShadow.glow(), aucun BackdropFilter".
  Widget _elevated(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    // Dégradé à peine perceptible — deux teintes très proches, jamais un
    // effet marqué (cf. `AppGradients.premiumBackground`, même philosophie).
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [AppColors.premiumSurfaceElevatedDark, Color(0xFF131C30)]
          : const [Colors.white, AppColors.premiumBgLight],
    );
    return PremiumCard(
      padding: padding,
      margin: margin,
      onTap: onTap,
      semanticLabel: semanticLabel,
      gradient: gradient,
      borderRadius: AppRadius.premiumXlR,
      border: Border.all(
        color: AppColors.premiumBorder(brightness),
        width: 1,
      ),
      shadows: [...AppShadow.card, ...AppShadow.glow()],
      child: child,
    );
  }

  Widget _tinted(BuildContext context, Color accent, Color bgLight) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PremiumCard(
      padding: padding,
      margin: margin,
      onTap: onTap,
      semanticLabel: semanticLabel,
      color: isDark ? accent.withValues(alpha: 0.12) : bgLight,
      border: Border.all(color: accent.withValues(alpha: 0.35), width: 1),
      shadows: AppShadow.xs,
      child: child,
    );
  }
}
