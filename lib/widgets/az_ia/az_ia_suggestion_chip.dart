import 'package:flutter/material.dart';

import '../../theme/az_ia_theme.dart';

class AzIaSuggestionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const AzIaSuggestionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: AzIaTheme.surface.withValues(alpha: 0.92),
        borderRadius: AzIaTheme.pillRadius,
        child: InkWell(
          onTap: onTap,
          borderRadius: AzIaTheme.pillRadius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: AzIaTheme.pillRadius,
              border: Border.all(
                  color: AzIaTheme.electricBlue.withValues(alpha: 0.42)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: AzIaTheme.azOrangeLight),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AzIaTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
