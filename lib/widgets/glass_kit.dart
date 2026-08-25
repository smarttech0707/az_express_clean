import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

// ══════════════════════════════════════════════════════════════════════════════
// GLASS KIT — AZ Express Premium UI Components
// iOS 26 "Liquid Glass" design language adapté Android
// ══════════════════════════════════════════════════════════════════════════════

// ── GlassCard ────────────────────────────────────────────────────────────────
/// Carte avec BackdropFilter blur — effet optimal sur fond coloré (map, gradient).
/// Sur fond uni clair, l'effet est plus subtil mais le border + shadow restent premium.
class GlassCard extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadiusGeometry borderRadius;
  final Color? fillColor;
  final double blurStrength;
  final List<BoxShadow>? shadows;
  final Border? border;
  final VoidCallback? onTap;
  // Master Prompt 125 (Partie 2) — optionnel, purement additif : décrit la
  // carte pour un lecteur d'écran quand son contenu (image/icône) ne porte
  // pas de texte lisible à lui seul.
  final String? semanticLabel;

  const GlassCard({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.borderRadius = AppRadius.cardR,
    this.fillColor,
    this.blurStrength = 24,
    this.shadows,
    this.border,
    this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    // Mode sombre (Master Prompt 120) — le "verre" reste teinté du fond de
    // carte actif plutôt que blanc translucide en dur, sinon la carte
    // apparaîtrait comme un flash blanc sur un écran sombre.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveFill = fillColor ??
        (isDark ? const Color(0xF21E293B) : const Color(0xF2FFFFFF));
    final effectiveBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.55);

    final content = Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadows ?? AppShadow.card,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurStrength, sigmaY: blurStrength),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: effectiveFill,
              borderRadius: borderRadius,
              border: border ??
                  Border.all(
                    color: effectiveBorderColor,
                    width: 0.8,
                  ),
            ),
            child: child,
          ),
        ),
      ),
    );

    final wrapped =
        onTap != null ? ScaleTap(onTap: onTap, child: content) : content;
    // Master Prompt 125 — n'exclut pas la sémantique du contenu (une carte
    // peut déjà porter du texte lisible) : le libellé s'ajoute en complément,
    // utile surtout quand `child` est une image/icône sans texte.
    return semanticLabel == null
        ? wrapped
        : Semantics(
            label: semanticLabel, button: onTap != null, child: wrapped);
  }
}

// ── PremiumCard ───────────────────────────────────────────────────────────────
/// Carte blanche premium avec ombre douce — fonctionne sur tous les fonds.
/// À utiliser partout où GlassCard n'est pas nécessaire.
class PremiumCard extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadiusGeometry borderRadius;
  final Color? color;
  final List<BoxShadow>? shadows;
  final Border? border;
  final VoidCallback? onTap;
  final Gradient? gradient;
  // Master Prompt 125 (Partie 2) — voir GlassCard, même usage.
  final String? semanticLabel;

  const PremiumCard({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.borderRadius = AppRadius.cardR,
    this.color,
    this.shadows,
    this.border,
    this.onTap,
    this.gradient,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor =
        color ?? (isDark ? AppColors.cardDark : AppColors.card);
    final effectiveBorderColor =
        isDark ? AppColors.dividerDark : AppColors.divider;

    final content = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: gradient != null ? null : effectiveColor,
        gradient: gradient,
        borderRadius: borderRadius,
        boxShadow: shadows ?? AppShadow.card,
        border: border ??
            Border.all(
              color: effectiveBorderColor,
              width: 0.5,
            ),
      ),
      child: child,
    );

    final wrapped =
        onTap != null ? ScaleTap(onTap: onTap, child: content) : content;
    return semanticLabel == null
        ? wrapped
        : Semantics(
            label: semanticLabel, button: onTap != null, child: wrapped);
  }
}

// ── AzShimmer ────────────────────────────────────────────────────────────────
/// Squelette de chargement avec effet shimmer.
/// Utilise flutter_animate pour une animation fluide optimisée bas de gamme.
class AzShimmer extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadiusGeometry? borderRadius;
  final double radius;

  const AzShimmer({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
    this.radius = AppRadius.md,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final br = borderRadius ?? BorderRadius.circular(radius);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? AppColors.dividerDark : AppColors.divider,
        borderRadius: br,
      ),
    ).animate(onPlay: (c) => c.repeat()).shimmer(
          duration: const Duration(milliseconds: 1400),
          color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.75),
          angle: 0.35,
        );
  }
}

// ── AzShimmerRow — ligne de shimmer pré-composée ─────────────────────────────
class AzShimmerRow extends StatelessWidget {
  final double? iconSize;
  final double lineHeight;
  final double maxWidth;
  final double spacing;

  const AzShimmerRow({
    super.key,
    this.iconSize = 40,
    this.lineHeight = 12,
    this.maxWidth = 180,
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (iconSize != null) ...[
          AzShimmer(width: iconSize!, height: iconSize!, radius: AppRadius.md),
          SizedBox(width: spacing),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AzShimmer(
                  width: maxWidth, height: lineHeight, radius: AppRadius.xs),
              const SizedBox(height: 6),
              AzShimmer(
                  width: maxWidth * 0.65,
                  height: lineHeight - 2,
                  radius: AppRadius.xs),
            ],
          ),
        ),
      ],
    );
  }
}

// ── ScaleTap ──────────────────────────────────────────────────────────────────
/// Wrapper d'effet de pression — scale + haptic sur n'importe quel widget.
/// Différent de [ScaleButton] qui est réservé aux ElevatedButton.
class ScaleTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scaleDown;
  final Duration duration;
  final bool haptic;

  const ScaleTap({
    super.key,
    required this.child,
    this.onTap,
    this.scaleDown = 0.95,
    this.duration = const Duration(milliseconds: 110),
    this.haptic = true,
  });

  @override
  State<ScaleTap> createState() => _ScaleTapState();
}

class _ScaleTapState extends State<ScaleTap>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _scale = Tween<double>(begin: 1.0, end: widget.scaleDown)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (widget.onTap == null) return;
        if (widget.haptic) HapticFeedback.lightImpact();
        _ctrl.forward();
      },
      onPointerUp: (_) => _ctrl.reverse(),
      onPointerCancel: (_) => _ctrl.reverse(),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _scale,
          builder: (_, child) =>
              Transform.scale(scale: _scale.value, child: child),
          child: widget.child,
        ),
      ),
    );
  }
}

// ── StatusPill ────────────────────────────────────────────────────────────────
/// Badge de statut coloré (pill) avec fond translucide.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  final double fontSize;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.pillR,
        border: Border.all(color: color.withValues(alpha: 0.28), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ── GradientIconBox ───────────────────────────────────────────────────────────
/// Boîte d'icône avec fond dégradé — utilisée dans les cartes de menu admin.
class GradientIconBox extends StatelessWidget {
  final IconData icon;
  final List<Color> gradient;
  final double size;
  final double iconSize;
  final BorderRadiusGeometry? borderRadius;

  const GradientIconBox({
    super.key,
    required this.icon,
    required this.gradient,
    this.size = 44,
    this.iconSize = 22,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: borderRadius ?? AppRadius.lgR,
        boxShadow: [
          BoxShadow(
            color: gradient.first.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: iconSize),
    );
  }
}

// ── AzDivider ─────────────────────────────────────────────────────────────────
/// Séparateur premium avec dégradé de disparition aux extrémités.
class AzDivider extends StatelessWidget {
  final EdgeInsetsGeometry? margin;

  const AzDivider({super.key, this.margin});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor = isDark ? AppColors.dividerDark : AppColors.divider;
    return Container(
      margin: margin ?? const EdgeInsets.symmetric(vertical: 8),
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            lineColor,
            lineColor,
            Colors.transparent,
          ],
          stops: const [0.0, 0.15, 0.85, 1.0],
        ),
      ),
    );
  }
}
