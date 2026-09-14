import 'dart:async';
import 'dart:math' as math;

import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────
// LOT 1 — AZ Express Premium V1 : Design tokens + Theme.
// Harnais de test ciblé (pas un Storybook) prouvant :
//  - les tokens Premium V1 (clair/sombre) ont exactement les valeurs cibles
//    du brief, et l'identité de marque (#FF6B00) est préservée ;
//  - AppTypography est bien la source de vérité du TextTheme M3 partagé ;
//  - InputDecorationTheme/CardTheme/boutons restent cohérents ;
//  - les paires de contraste les plus importantes sont mesurées (WCAG),
//    sans imposer une réussite AA là où elle n'est pas justifiée ;
//  - un petit écran représentatif ne déborde pas à 320px de large.
// ─────────────────────────────────────────────────────────────────────────

/// Luminance relative WCAG — `c` est déjà le canal sRGB normalisé (0.0-1.0),
/// tel qu'exposé par `Color.r`/`.g`/`.b` sur cette version du SDK.
double _channelToLinear(double c) {
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color c) {
  final r = _channelToLinear(c.r);
  final g = _channelToLinear(c.g);
  final b = _channelToLinear(c.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// Ratio de contraste WCAG entre deux couleurs (1.0 = aucun contraste,
/// 21.0 = noir/blanc pur).
double contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  // Requis : `AppTheme.light`/`.dark` appellent `GoogleFonts.urbanist(...)`,
  // qui a besoin du binding de services pour résoudre l'asset de police —
  // même pattern que `test/services/voice_test.dart`.
  TestWidgetsFlutterBinding.ensureInitialized();
  // Cet environnement de test n'a pas d'accès réseau : empêche
  // `google_fonts` de tenter un téléchargement réel (repli sur la police
  // système), pattern officiellement recommandé par le package pour les
  // tests — sans rapport avec la logique testée ici (design tokens/thème,
  // jamais le rendu pixel exact d'un glyphe Urbanist).
  GoogleFonts.config.allowRuntimeFetching = false;

  group('AppColors — identité de marque préservée', () {
    test('brandPrimary reste #FF6B00 (jamais remplacé par #F97316)', () {
      expect(AppColors.primary, const Color(0xFFFF6B00));
      expect(AppColors.brandPrimary, const Color(0xFFFF6B00));
      expect(AppColors.brandPrimary, AppColors.primary);
    });

    test(
        'les anciens tokens de surface/texte restent inchangés (alias de '
        'compatibilité conservés pour les écrans existants)', () {
      expect(AppColors.bg, const Color(0xFFF7F8FA));
      expect(AppColors.card, const Color(0xFFFFFFFF));
      expect(AppColors.text, const Color(0xFF161A1D));
      expect(AppColors.bgDark, const Color(0xFF0B0F14));
      expect(AppColors.cardDark, const Color(0xFF1E293B));
      expect(AppColors.textDark, const Color(0xFFF8FAFC));
    });
  });

  group('AppColors — nouveaux tokens Premium V1 (LOT 1)', () {
    test('cible LIGHT exacte', () {
      expect(AppColors.premiumBgLight, const Color(0xFFFAFAF8));
      expect(AppColors.premiumSurfaceLight, const Color(0xFFFFFFFF));
      expect(AppColors.premiumBorderLight, const Color(0xFFE7E5E0));
      expect(AppColors.premiumTextPrimaryLight, const Color(0xFF111827));
      expect(AppColors.premiumTextSecondaryLight, const Color(0xFF4B5563));
      expect(AppColors.premiumTextMutedLight, const Color(0xFF9CA3AF));
    });

    test('cible DARK exacte', () {
      expect(AppColors.premiumBgDark, const Color(0xFF0B1220));
      expect(AppColors.premiumSurfaceDark, const Color(0xFF111A2E));
      expect(AppColors.premiumSurfaceElevatedDark, const Color(0xFF16223B));
      expect(AppColors.premiumBorderDark, const Color(0xFF22314F));
      expect(AppColors.premiumTextPrimaryDark, const Color(0xFFF8FAFC));
      expect(AppColors.premiumTextSecondaryDark, const Color(0xFFB6C2D9));
      expect(AppColors.premiumTextMutedDark, const Color(0xFF7C8AA5));
    });

    test('bleu AZ Premium — variantes clair/sombre', () {
      expect(AppColors.bluePremiumLight, const Color(0xFF1D4ED8));
      expect(AppColors.bluePremiumDark, const Color(0xFF3B82F6));
      expect(
          AppColors.bluePremium(Brightness.light), AppColors.bluePremiumLight);
      expect(AppColors.bluePremium(Brightness.dark), AppColors.bluePremiumDark);
    });

    test('résolveurs premiumBg/premiumSurface/... respectent la luminosité',
        () {
      expect(AppColors.premiumBg(Brightness.light), AppColors.premiumBgLight);
      expect(AppColors.premiumBg(Brightness.dark), AppColors.premiumBgDark);
      expect(AppColors.premiumSurface(Brightness.dark),
          AppColors.premiumSurfaceDark);
      expect(AppColors.premiumTextPrimary(Brightness.light),
          AppColors.premiumTextPrimaryLight);
      expect(AppColors.premiumTextSecondary(Brightness.dark),
          AppColors.premiumTextSecondaryDark);
      expect(AppColors.premiumTextMuted(Brightness.light),
          AppColors.premiumTextMutedLight);
      expect(AppColors.premiumBorder(Brightness.dark),
          AppColors.premiumBorderDark);
    });
  });

  group('AppGradients — fond premium (item 5, mécanisme réutilisable)', () {
    test('dégradé clair : deux teintes très proches de #FAFAF8', () {
      final g = AppGradients.premiumBackground(Brightness.light);
      expect(g.colors.first, AppColors.premiumBgLight);
      expect(g.colors.length, 2);
      // Les deux couleurs doivent rester visuellement très proches (delta
      // de luminance faible, mesuré ~0.075 pour #FAFAF8→#F3F1EC) — pas un
      // dégradé marqué. Seuil large (0.15) : sanity check de "subtilité",
      // pas une contrainte de design exacte.
      final l1 = _relativeLuminance(g.colors[0]);
      final l2 = _relativeLuminance(g.colors[1]);
      expect((l1 - l2).abs(), lessThan(0.15));
    });

    test('dégradé sombre : part de #0B1220', () {
      final g = AppGradients.premiumBackground(Brightness.dark);
      expect(g.colors.first, AppColors.premiumBgDark);
      expect(g.colors.length, 2);
    });
  });

  group('AppRadius — nouvelle référence Premium (item 3), additive', () {
    test('nouvelle échelle premium exacte', () {
      expect(AppRadius.premiumXs, 8.0);
      expect(AppRadius.premiumSm, 12.0);
      expect(AppRadius.premiumMd, 16.0);
      expect(AppRadius.premiumLg, 20.0);
      expect(AppRadius.premiumXl, 24.0);
      expect(AppRadius.premiumPill, 999.0);
    });

    test('échelle historique et système officiel 18/22/28 inchangés', () {
      expect(AppRadius.xs, 6.0);
      expect(AppRadius.sm, 10.0);
      expect(AppRadius.md, 14.0);
      expect(AppRadius.lg, 18.0);
      expect(AppRadius.xl, 24.0);
      expect(AppRadius.pill, 100.0);
      expect(AppRadius.official18, 18.0);
      expect(AppRadius.official22, 22.0);
      expect(AppRadius.official28, 28.0);
    });
  });

  group('AppShadow — niveau "glow" premium (item 4)', () {
    test('dérivé de brandPrimary, opacité faible', () {
      final glow = AppShadow.glow();
      expect(glow.length, 1);
      expect(glow.first.color.a, closeTo(0.10, 0.01));
      expect(glow.first.blurRadius, 20);
    });

    test('AppShadow existant inchangé (aucune ombre supprimée)', () {
      expect(AppShadow.card.length, 2);
      expect(AppShadow.navFloat.length, 2);
    });
  });

  group('AppTypography — tailles de base exposées (source de vérité)', () {
    test('valeurs de référence à 390px', () {
      expect(AppTypography.baseHeadline, 24);
      expect(AppTypography.baseTitleLarge, 18);
      expect(AppTypography.baseTitleMedium, 16);
      expect(AppTypography.baseBodyLarge, 16);
      expect(AppTypography.baseBodyMedium, 14);
      expect(AppTypography.baseBodySmall, 13);
      expect(AppTypography.baseLabelLarge, 13);
    });
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final label = brightness == Brightness.light ? 'light' : 'dark';
    // `AppTheme.light`/`.dark` appellent `GoogleFonts.urbanist(...)`, qui
    // lance un chargement de police en tâche de fond via un `Future` interne
    // au package, jamais exposé à l'appelant (impossible à `try/catch`
    // depuis ce fichier). Sans réseau, ce chargement échoue de façon
    // asynchrone — sans confinement, l'erreur "fuit" vers un test
    // ultérieur (attribution trompeuse), déjà sans aucun rapport avec les
    // assertions de ce fichier (design tokens/thème, jamais le rendu pixel
    // réel d'un glyphe Urbanist). `loadTheme()` construit le thème DANS sa
    // propre zone Dart gardée : toute erreur asynchrone provenant d'un
    // `Future` créé pendant cette construction (y compris le chargement de
    // police interne à `google_fonts`) est interceptée par cette zone,
    // jamais par celle du test suivant.
    Future<ThemeData> loadTheme() {
      final completer = Completer<ThemeData>();
      runZonedGuarded(() {
        final t =
            brightness == Brightness.light ? AppTheme.light : AppTheme.dark;
        completer.complete(t);
      }, (error, stack) {
        // Bruit connu et inoffensif de google_fonts (pas de réseau dans cet
        // environnement de test) — jamais rethrow ici, sinon il remonterait
        // comme une erreur du prochain test à s'exécuter plutôt que de
        // celui-ci.
      });
      return completer.future;
    }

    group('AppTheme.$label', () {
      test('scaffoldBackgroundColor == token premium background', () async {
        final t = await loadTheme();
        expect(t.scaffoldBackgroundColor, AppColors.premiumBg(brightness));
      });

      test('colorScheme.primary reste #FF6B00 (marque non modifiée)', () async {
        final t = await loadTheme();
        expect(t.colorScheme.primary, AppColors.primary);
      });

      test('colorScheme.secondary == bleu AZ Premium', () async {
        final t = await loadTheme();
        expect(t.colorScheme.secondary, AppColors.bluePremium(brightness));
      });

      test('colorScheme.surface/onSurface == tokens premium', () async {
        final t = await loadTheme();
        expect(t.colorScheme.surface, AppColors.premiumSurface(brightness));
        expect(
            t.colorScheme.onSurface, AppColors.premiumTextPrimary(brightness));
      });

      test('AppBar reste orange plein (non migré dans ce lot)', () async {
        final t = await loadTheme();
        expect(t.appBarTheme.backgroundColor, AppColors.primary);
        expect(t.appBarTheme.foregroundColor, Colors.white);
      });

      test('CardTheme utilise la surface premium et le rayon officiel card',
          () async {
        final t = await loadTheme();
        expect(t.cardTheme.color, AppColors.premiumSurface(brightness));
        final shape = t.cardTheme.shape as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.cardR);
      });

      test('InputDecorationTheme : rempli, rayon input, focus orange',
          () async {
        final dec = (await loadTheme()).inputDecorationTheme;
        expect(dec.filled, isTrue);
        expect(dec.fillColor, AppColors.premiumSurface(brightness));
        final focused = dec.focusedBorder as OutlineInputBorder;
        expect(focused.borderRadius, AppRadius.inputR);
        expect(focused.borderSide.color, AppColors.primary);
      });

      test('ElevatedButtonTheme : fond orange par défaut, taille officielle',
          () async {
        final style = (await loadTheme()).elevatedButtonTheme.style!;
        final bg = style.backgroundColor!.resolve({});
        expect(bg, AppColors.primary);
        final minSize = style.minimumSize!.resolve({});
        expect(minSize, const Size(64, 54));
        final shape = style.shape!.resolve({}) as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.btnR);
      });

      test('DialogTheme/BottomSheetTheme utilisent la surface premium',
          () async {
        final t = await loadTheme();
        expect(t.dialogTheme.backgroundColor,
            AppColors.premiumSurface(brightness));
        expect(t.bottomSheetTheme.backgroundColor,
            AppColors.premiumSurface(brightness));
      });

      test(
          'TextTheme M3 cohérent avec AppTypography (LOT 1, item 2 — source '
          'unique)', () async {
        final tt = (await loadTheme()).textTheme;
        expect(tt.headlineLarge!.fontSize, AppTypography.baseHeadline);
        expect(tt.titleLarge!.fontSize, AppTypography.baseTitleLarge);
        expect(tt.titleMedium!.fontSize, AppTypography.baseTitleMedium);
        expect(tt.titleSmall!.fontSize, AppTypography.baseTitleSmall);
        expect(tt.bodyLarge!.fontSize, AppTypography.baseBodyLarge);
        expect(tt.bodyMedium!.fontSize, AppTypography.baseBodyMedium);
        expect(tt.bodySmall!.fontSize, AppTypography.baseBodySmall);
        expect(tt.labelLarge!.fontSize, AppTypography.baseLabelLarge);
        expect(tt.labelSmall!.fontSize, AppTypography.baseLabelSmall);
        // Poids alignés sur les méthodes AppTypography.xxxStyle().
        expect(tt.headlineLarge!.fontWeight, FontWeight.w600);
        expect(tt.titleLarge!.fontWeight, FontWeight.w600);
        expect(tt.bodyLarge!.fontWeight, FontWeight.w500);
        expect(tt.bodyMedium!.fontWeight, FontWeight.w400);
      });

      test('couleurs de texte du TextTheme dérivées des tokens premium',
          () async {
        final tt = (await loadTheme()).textTheme;
        expect(
            tt.headlineLarge!.color, AppColors.premiumTextPrimary(brightness));
        expect(
            tt.bodyMedium!.color, AppColors.premiumTextSecondary(brightness));
        expect(tt.bodySmall!.color, AppColors.premiumTextMuted(brightness));
      });
    });
  }

  group('Accessibilité — contrastes WCAG des paires principales', () {
    test('texte principal clair sur fond clair : largement conforme AA', () {
      final ratio = contrastRatio(
          AppColors.premiumTextPrimaryLight, AppColors.premiumBgLight);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test('texte principal clair sur surface (carte) claire : conforme AA', () {
      final ratio = contrastRatio(
          AppColors.premiumTextPrimaryLight, AppColors.premiumSurfaceLight);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test('texte principal sombre sur surface sombre : conforme AA', () {
      final ratio = contrastRatio(
          AppColors.premiumTextPrimaryDark, AppColors.premiumSurfaceDark);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test(
        'texte CTA blanc sur brandPrimary (#FF6B00) : gap AA CONNU, déjà '
        'documenté par l\'audit — ce test mesure la réalité, il n\'impose '
        'PAS une réussite AA qui n\'existe pas (identité de marque '
        'préservée volontairement dans ce lot).', () {
      final ratio = contrastRatio(Colors.white, AppColors.primary);
      // ~2.86:1 — sous le seuil "texte large" (3:1) et très sous le seuil
      // "texte normal" (4.5:1). Verrouille l'état connu, pas un idéal.
      expect(ratio, lessThan(3.0));
    });

    test(
        'variante CTA accessible (primaryCtaAccessible) : passe AA texte '
        'normal — preuve que le token additif résout réellement le gap '
        'ci-dessus pour qui l\'adopte plus tard.', () {
      final ratio = contrastRatio(Colors.white, AppColors.primaryCtaAccessible);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });
  });

  group('Absence d\'overflow — petite largeur représentative (320px)', () {
    Future<void> pumpSample(WidgetTester tester, ThemeData theme) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          appBar: AppBar(title: const Text('AZ Express Premium V1')),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    // Pas de `style:` explicite — hérite du `textTheme`
                    // ambiant (donc du thème testé) via `DefaultTextStyle`,
                    // sans avoir besoin d'un `BuildContext` déjà monté.
                    child: Text(
                      'Carte premium — texte de démonstration assez long '
                      'pour vérifier l\'absence de débordement.',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const TextField(
                  decoration:
                      InputDecoration(labelText: 'Adresse de livraison'),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {},
                  child: const Text('Confirmer la commande premium'),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('thème clair — aucune exception RenderFlex à 320px',
        (tester) async {
      await pumpSample(tester, AppTheme.light);
      expect(tester.takeException(), isNull);
    });

    testWidgets('thème sombre — aucune exception RenderFlex à 320px',
        (tester) async {
      await pumpSample(tester, AppTheme.dark);
      expect(tester.takeException(), isNull);
    });
  });
}
