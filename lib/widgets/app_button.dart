import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/app_haptics.dart';

/// Master Prompt 126 (Partie 7) — les 7 variantes demandées, un seul
/// composant. "Disabled" n'est pas un 7ᵉ style séparé à choisir : n'importe
/// quelle variante devient automatiquement son propre état désactivé quand
/// `onPressed` est `null` (cohérent avec le comportement natif de
/// `ElevatedButton`/`OutlinedButton` déjà utilisé ailleurs dans l'app —
/// dupliquer un état "disabled" par variante aurait été un doublon inutile).
enum AppButtonVariant { primary, secondary, outlined, ghost, danger, success }

/// Bouton unique du Design System — remplace les usages ad hoc de
/// `ElevatedButton`/`OutlinedButton`/`Container`+`GestureDetector` codés en
/// dur écran par écran. Toutes les variantes partagent la même géométrie
/// (rayon officiel 18, hauteur 54, typographie 16 SemiBold), le même
/// retour haptique (`AppHaptics.tap`) et le même effet de pression.
///
/// Adoption prospective (comme `lib/repositories/` avant lui) : ce widget
/// est prêt à être utilisé par tout nouvel écran ou toute prochaine
/// modification d'écran existant — il ne remplace pas rétroactivement les
/// centaines de boutons déjà en place dans l'app (migration non demandée,
/// à fort risque de régression visuelle si faite en masse sans revue).
class AppButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool loading;
  final bool fullWidth;
  final String? semanticLabel;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = AppButtonVariant.primary,
    this.loading = false,
    this.fullWidth = true,
    this.semanticLabel,
  });

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 100));
    _scale = Tween<double>(begin: 1.0, end: 0.96)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  _ButtonColors _colorsFor(AppButtonVariant v, bool isDark) {
    switch (v) {
      case AppButtonVariant.primary:
        return const _ButtonColors(
          background: AppColors.primary,
          foreground: Colors.white,
          border: null,
        );
      case AppButtonVariant.secondary:
        return const _ButtonColors(
          background: AppColors.blue,
          foreground: Colors.white,
          border: null,
        );
      case AppButtonVariant.outlined:
        return const _ButtonColors(
          background: Colors.transparent,
          foreground: AppColors.primary,
          border: AppColors.primary,
        );
      case AppButtonVariant.ghost:
        return _ButtonColors(
          background: Colors.transparent,
          foreground: isDark ? AppColors.textDark : AppColors.text,
          border: null,
        );
      case AppButtonVariant.danger:
        return const _ButtonColors(
          background: AppColors.red,
          foreground: Colors.white,
          border: null,
        );
      case AppButtonVariant.success:
        return const _ButtonColors(
          background: AppColors.success,
          foreground: Colors.white,
          border: null,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = _colorsFor(widget.variant, isDark);
    final bg = _enabled ? c.background : c.background.withValues(alpha: 0.45);
    final fg = _enabled ? c.foreground : c.foreground.withValues(alpha: 0.6);

    final content = Listener(
      onPointerDown: (_) {
        if (!_enabled) return;
        _ctrl.forward();
        AppHaptics.tap();
      },
      onPointerUp: (_) => _ctrl.reverse(),
      onPointerCancel: (_) => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
        child: GestureDetector(
          onTap: _enabled ? widget.onPressed : null,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: widget.fullWidth ? double.infinity : null,
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadius.official18R,
              border: c.border != null
                  ? Border.all(
                      color: _enabled ? c.border! : c.border!.withValues(alpha: 0.45),
                      width: 1.5)
                  : null,
            ),
            alignment: Alignment.center,
            child: widget.loading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: fg),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, size: 20, color: fg),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          widget.label,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.buttonStyle(context, color: fg),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );

    final label = widget.semanticLabel ?? widget.label;
    return Semantics(
      label: label,
      button: true,
      enabled: _enabled,
      excludeSemantics: true,
      child: content,
    );
  }
}

class _ButtonColors {
  final Color background;
  final Color foreground;
  final Color? border;
  const _ButtonColors({
    required this.background,
    required this.foreground,
    required this.border,
  });
}
