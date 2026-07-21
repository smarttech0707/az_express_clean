import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'glass_kit.dart';

/// Master Prompt 126 (Partie 8) — les 7 variantes demandées, construites
/// sur les cartes déjà existantes (`GlassCard`/`PremiumCard`, Master Prompt
/// 120) plutôt que réécrites : "Standard"/"Glass"/"Premium" délèguent
/// directement, "Information"/"Warning"/"Error"/"Success" sont des
/// `PremiumCard` teintées de la couleur sémantique correspondante — pas une
/// 4ᵉ implémentation de carte, juste un jeu de couleurs different sur le
/// même composant.
enum AppCardVariant { standard, glass, premium, info, warning, error, success }

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

  @override
  Widget build(BuildContext context) {
    switch (variant) {
      case AppCardVariant.standard:
        return PremiumCard(
          padding: padding,
          margin: margin,
          onTap: onTap,
          semanticLabel: semanticLabel,
          child: child,
        );
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
