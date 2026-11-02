import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Indicateur de chargement centré, aux couleurs du thème (orange lisible en
/// clair comme en sombre), annoncé « Chargement » aux lecteurs d'écran.
class AppLoading extends StatelessWidget {
  final String? message;

  const AppLoading({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Semantics(
      label: message ?? 'Chargement',
      liveRegion: true,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              strokeWidth: 3,
              color: AppColors.primaryText(brightness),
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Text(message!, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}

/// Squelette de liste pour les écrans qui chargent des cartes (commandes,
/// produits, annonces) : donne la forme du contenu à venir au lieu d'un vide.
///
/// Conçu pour les téléphones d'entrée de gamme : blocs statiques et UNE seule
/// animation d'opacité pour toute la liste (pas un shimmer par bloc), figée
/// quand l'utilisateur a désactivé les animations.
class AppListSkeleton extends StatefulWidget {
  final int itemCount;
  final double itemHeight;
  final EdgeInsetsGeometry padding;

  const AppListSkeleton({
    super.key,
    this.itemCount = 6,
    this.itemHeight = 76,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  @override
  State<AppListSkeleton> createState() => _AppListSkeletonState();
}

class _AppListSkeletonState extends State<AppListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final block = isDark ? AppColors.dividerDark : AppColors.divider;
    return Semantics(
      label: 'Chargement',
      liveRegion: true,
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.45, end: 1).animate(_pulse),
          child: ListView.separated(
            physics: const NeverScrollableScrollPhysics(),
            padding: widget.padding,
            itemCount: widget.itemCount,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (_, __) => SizedBox(
              height: widget.itemHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: block,
                  borderRadius: AppRadius.cardR,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
