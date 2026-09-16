import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// État vide partagé des parcours Services & Commerce Premium V1.
///
/// Purement présentationnel : aucune action n'est créée implicitement.
class PremiumEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color accent;
  final Widget? action;

  const PremiumEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.accent = AppColors.primary,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 440),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            color: AppColors.premiumSurfaceElevated(brightness),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.premiumBorder(brightness)),
            boxShadow: AppShadow.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 30, color: accent),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTypography.titleLargeStyle(
                  context,
                  color: AppColors.premiumTextPrimary(brightness),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppTypography.bodyMediumStyle(
                  context,
                  color: AppColors.premiumTextSecondary(brightness),
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
