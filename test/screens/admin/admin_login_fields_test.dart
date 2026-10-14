import 'package:az_express/screens/admin/admin_login.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('champs de connexion Admin', () {
    testWidgets('le texte saisi reste lisible en clair et en sombre',
        (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme:
                brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
            home: Scaffold(
              body: TextField(
                style: adminLoginFieldTextStyle(),
                decoration: adminLoginFieldDecoration(
                  labelText: 'Identifiant',
                  prefixIcon: Icons.person,
                ),
              ),
            ),
          ),
        );

        final editableText =
            tester.widget<EditableText>(find.byType(EditableText));
        expect(editableText.style.color, AppColors.text);
        expect(find.text('Identifiant'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    test('la décoration définit des couleurs lisibles pour tous les états', () {
      final decoration = adminLoginFieldDecoration(
        labelText: 'Mot de passe',
        prefixIcon: Icons.lock,
      );

      expect(adminLoginFieldTextStyle().color, AppColors.text);
      expect(decoration.fillColor, Colors.white);
      expect(decoration.labelStyle?.color, AppColors.textMuted);
      expect(decoration.floatingLabelStyle?.color, AppColors.primary);
      expect(decoration.hintStyle?.color, AppColors.textLight);
      expect(decoration.prefixIconColor, AppColors.textMuted);
      final enabledBorder = decoration.enabledBorder! as OutlineInputBorder;
      final focusedBorder = decoration.focusedBorder! as OutlineInputBorder;
      final errorBorder = decoration.errorBorder! as OutlineInputBorder;
      final focusedErrorBorder =
          decoration.focusedErrorBorder! as OutlineInputBorder;
      final disabledBorder = decoration.disabledBorder! as OutlineInputBorder;
      expect(enabledBorder.borderSide.color, AppColors.border);
      expect(
        focusedBorder.borderSide.color,
        AppColors.primary,
      );
      expect(focusedBorder.borderSide.width, 2);
      expect(errorBorder.borderSide.color, AppColors.error);
      expect(focusedErrorBorder.borderSide.color, AppColors.error);
      expect(disabledBorder.borderSide.color, AppColors.divider);
    });

    testWidgets('le champ garde sa lisibilité quand il est désactivé',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: TextField(
              enabled: false,
              style: adminLoginFieldTextStyle(),
              decoration: adminLoginFieldDecoration(
                labelText: 'Identifiant',
                prefixIcon: Icons.person,
              ),
            ),
          ),
        ),
      );

      final inputDecorator =
          tester.widget<InputDecorator>(find.byType(InputDecorator));
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(inputDecorator.decoration.disabledBorder, isNotNull);
    });
  });
}
