import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum AppSnackType { success, error, warning, info }

/// Messages éphémères typés (succès / erreur / avertissement / information).
///
/// Remplace les `SnackBar(backgroundColor: Colors.red / green / orange)`
/// écrits à la main (plus de 150 dans l'app) : mêmes couleurs partout, texte
/// lisible (WCAG AA, ≥ 4,5:1), icône pour ne pas reposer sur la couleur seule,
/// annoncé par les lecteurs d'écran. La forme, la police et la position
/// viennent du `snackBarTheme` de [AppTheme].
class AppSnack {
  AppSnack._();

  /// Fond et texte de chaque type — chaque paire dépasse 4,5:1.
  static ({Color background, Color foreground, IconData icon}) styleOf(
      AppSnackType type) {
    switch (type) {
      case AppSnackType.success:
        return (
          background: AppColors.successStrong,
          foreground: Colors.white,
          icon: Icons.check_circle_rounded,
        );
      case AppSnackType.error:
        return (
          background: AppColors.errorStrong,
          foreground: Colors.white,
          icon: Icons.error_rounded,
        );
      case AppSnackType.warning:
        // Le jaune/orange d'avertissement exige un texte sombre (8,2:1).
        return (
          background: AppColors.warning,
          foreground: AppColors.onPrimary,
          icon: Icons.warning_amber_rounded,
        );
      case AppSnackType.info:
        return (
          background: AppColors.blueDark,
          foreground: Colors.white,
          icon: Icons.info_rounded,
        );
    }
  }

  static SnackBar build(
    String message, {
    AppSnackType type = AppSnackType.info,
    Duration duration = const Duration(seconds: 4),
    SnackBarAction? action,
  }) {
    final style = styleOf(type);
    return SnackBar(
      backgroundColor: style.background,
      duration: duration,
      action: action,
      content: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(style.icon, color: style.foreground, size: 22),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(message, style: TextStyle(color: style.foreground)),
            ),
          ],
        ),
      ),
    );
  }

  /// Affiche le message en remplaçant celui qui serait déjà à l'écran.
  static void show(
    BuildContext context,
    String message, {
    AppSnackType type = AppSnackType.info,
    Duration duration = const Duration(seconds: 4),
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          build(message, type: type, duration: duration, action: action));
  }
}
