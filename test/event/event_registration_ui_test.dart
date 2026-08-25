import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/event/screens/event_provider_registration.dart';
import 'package:az_express/theme/app_theme.dart';

double _luminance(Color color) => color.computeLuminance();

double _contrast(Color first, Color second) {
  final light = _luminance(first) > _luminance(second)
      ? _luminance(first)
      : _luminance(second);
  final dark = _luminance(first) < _luminance(second)
      ? _luminance(first)
      : _luminance(second);
  return (light + 0.05) / (dark + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in {
    'clair': const ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.blueDark,
      onSecondary: Colors.white,
      surface: AppColors.card,
      onSurface: AppColors.text,
    ),
    'sombre': const ColorScheme.dark(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.blueLight,
      onSecondary: AppColors.bgDark,
      surface: AppColors.cardDark,
      onSurface: AppColors.textDark,
    ),
  }.entries) {
    test('contraste des choix en thème ${entry.key}', () {
      final colors = entry.value;

      expect(
        _contrast(
          eventRegistrationChoiceForeground(colors, false),
          eventRegistrationChoiceBackground(colors, false),
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(
          eventRegistrationChoiceForeground(colors, true),
          eventRegistrationChoiceBackground(colors, true),
        ),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  test('les catégories ajoutées sont uniques et sélectionnables', () {
    final values = eventRegistrationCategories.values.expand((e) => e).toList();
    expect(values.where((value) => value == 'Soutenance'), hasLength(1));
    expect(
        values.where((value) => value == 'Groupe traditionnel'), hasLength(1));
  });
}
