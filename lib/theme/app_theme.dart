import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ══════════════════════════════════════════════════════════════════════════════
// COULEURS — AZ Express Brand (Master Prompt 120, refonte premium 2026-07-15)
// Palette douce inspirée de Tailwind slate/orange/green/red/blue/amber —
// permet de dériver les teintes non fournies explicitement (pressed states,
// mode sombre) en restant cohérent avec un système reconnu.
// ══════════════════════════════════════════════════════════════════════════════
class AppColors {
  AppColors._();

  static const primary      = Color(0xFFF97316); // orange-500
  static const primaryLight = Color(0xFFFB923C); // orange-400 — "orange secondaire"
  static const primaryDark  = Color(0xFFEA580C); // orange-600 — état pressed
  static const primaryBg    = Color(0xFFFFF7ED); // orange-50 — teinte de fond

  static const primary05 = Color(0x0DF97316);
  static const primary08 = Color(0x14F97316);
  static const primary10 = Color(0x1AF97316);
  static const primary15 = Color(0x26F97316);
  static const primary20 = Color(0x33F97316);
  static const primary35 = Color(0x59F97316);

  // "Information" — bleu doux, alias sémantique explicite via `info`.
  static const blue      = Color(0xFF3B82F6); // blue-500
  static const blueDark  = Color(0xFF1D4ED8); // blue-700
  static const blueLight = Color(0xFF60A5FA); // blue-400
  static const blueBg    = Color(0xFFEFF6FF); // blue-50
  static const info      = blue;

  static const blue05 = Color(0x0D3B82F6);
  static const blue10 = Color(0x1A3B82F6);
  static const blue15 = Color(0x263B82F6);
  static const blue20 = Color(0x333B82F6);
  static const blue40 = Color(0x663B82F6);

  static const green    = Color(0xFF22C55E);
  static const greenBg  = Color(0xFFF0FDF4);
  static const green10  = Color(0x1A22C55E);

  static const purple   = Color(0xFF6A1B9A);
  static const purpleBg = Color(0xFFF3E5F5);

  static const red   = Color(0xFFEF4444);
  static const redBg = Color(0xFFFEF2F2);

  // "Avertissement" — n'existait pas avant cette passe, purement additif.
  static const warning   = Color(0xFFF59E0B); // amber-500
  static const warningBg = Color(0xFFFFFBEB); // amber-50

  static const bg       = Color(0xFFF8FAFC); // slate-50 — fond principal
  static const bgLight  = Color(0xFFFCFCFD);
  static const card     = Color(0xFFFFFFFF); // cartes
  static const text     = Color(0xFF1E293B); // slate-800 — titre
  static const textMuted = Color(0xFF334155); // slate-700 — texte principal
  static const textLight = Color(0xFF64748B); // slate-500 — texte secondaire
  static const divider  = Color(0xFFE2E8F0); // slate-200 — bordures
  static const border   = Color(0xFFE2E8F0);

  static const success  = Color(0xFF22C55E);
  static const error    = Color(0xFFEF4444);

  static const white08 = Color(0x14FFFFFF);
  static const white10 = Color(0x1AFFFFFF);
  static const white20 = Color(0x33FFFFFF);
  static const white30 = Color(0x4DFFFFFF);
  static const white50 = Color(0x80FFFFFF);
  static const white70 = Color(0xB3FFFFFF);

  static const black05 = Color(0x0D000000);
  static const black08 = Color(0x14000000);
  static const black10 = Color(0x1A000000);
  static const black12 = Color(0x1F000000);
  static const black15 = Color(0x26000000);
  static const black20 = Color(0x33000000);

  // ── Mode sombre (Master Prompt 120) — jamais de noir pur, mêmes teintes
  // "slate" foncées que le reste de la palette pour rester cohérent.
  static const bgDark        = Color(0xFF0F172A); // slate-900
  static const cardDark      = Color(0xFF1E293B); // slate-800
  static const textDark      = Color(0xFFF8FAFC); // slate-50
  static const textMutedDark = Color(0xFFCBD5E1); // slate-300
  static const textLightDark = Color(0xFF94A3B8); // slate-400
  static const dividerDark   = Color(0xFF334155); // slate-700
  static const borderDark    = Color(0xFF334155);
}

// ══════════════════════════════════════════════════════════════════════════════
// SYSTÈME TYPOGRAPHIQUE RESPONSIVE — Urbanist partout (Master Prompt 120)
// ══════════════════════════════════════════════════════════════════════════════
class AppTypography {
  AppTypography._();

  // ── Scale responsive (réf. 390px = iPhone 14) ──────────────────────────
  static double _scale(BuildContext context) =>
      (MediaQuery.of(context).size.width / 390.0).clamp(0.78, 1.30);

  static double _r(BuildContext context, double base) =>
      (base * _scale(context)).roundToDouble();

  // ── Tailles (Master Prompt 124 — hiérarchie exacte : titre principal 20,
  // titre secondaire 18, texte 16, texte secondaire 14, petit texte 13) ────
  static double displayLarge(BuildContext ctx)  => _r(ctx, 34);
  static double displayMedium(BuildContext ctx) => _r(ctx, 28);
  static double headline(BuildContext ctx)      => _r(ctx, 20);
  static double titleLarge(BuildContext ctx)    => _r(ctx, 18);
  static double titleMedium(BuildContext ctx)   => _r(ctx, 16);
  static double titleSmall(BuildContext ctx)    => _r(ctx, 14);
  static double bodyLarge(BuildContext ctx)     => _r(ctx, 16);
  static double bodyMedium(BuildContext ctx)    => _r(ctx, 14);
  static double bodySmall(BuildContext ctx)     => _r(ctx, 13);
  static double labelLarge(BuildContext ctx)    => _r(ctx, 13);
  static double labelMedium(BuildContext ctx)   => _r(ctx, 12);
  static double labelSmall(BuildContext ctx)    => _r(ctx, 11);

  // ── Constructeur de style — Urbanist partout (Master Prompt 120), plus
  // aucun branchement SF Pro (iOS)/Poppins (Android/Web) : une seule police
  // cohérente sur toutes les plateformes.
  static TextStyle _build({
    required BuildContext ctx,
    required double size,
    required FontWeight weight,
    Color? color,
    double letterSpacing = 0,
    bool display = false,
  }) {
    return GoogleFonts.urbanist(
      fontSize:      size,
      fontWeight:    weight,
      color:         color,
      letterSpacing: letterSpacing,
    );
  }

  // ── Styles complets ──────────────────────────────────────────────────────
  // Grand titre — Urbanist Bold 700.
  static TextStyle displayLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: displayLarge(ctx),
          weight: weight ?? FontWeight.w700,
          color: color ?? AppColors.text,
          letterSpacing: -0.5, display: true);

  static TextStyle displayMediumStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: displayMedium(ctx),
          weight: weight ?? FontWeight.w700,
          color: color ?? AppColors.text,
          letterSpacing: -0.3, display: true);

  // Titre écran — Urbanist SemiBold 600.
  static TextStyle headlineStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: headline(ctx),
          weight: weight ?? FontWeight.w600,
          color: color ?? AppColors.text,
          display: true);

  // Titre carte — Urbanist SemiBold 600.
  static TextStyle titleLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: titleLarge(ctx),
          weight: weight ?? FontWeight.w600,
          color: color ?? AppColors.text);

  static TextStyle titleMediumStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: titleMedium(ctx),
          weight: weight ?? FontWeight.w600,
          color: color ?? AppColors.text);

  static TextStyle titleSmallStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: titleSmall(ctx),
          weight: weight ?? FontWeight.w600,
          color: color ?? AppColors.text);

  // Texte — Urbanist Medium 500 (Master Prompt 124).
  static TextStyle bodyLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: bodyLarge(ctx),
          weight: weight ?? FontWeight.w500,
          color: color ?? AppColors.text);

  static TextStyle bodyMediumStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: bodyMedium(ctx),
          weight: weight ?? FontWeight.w400,
          color: color ?? AppColors.textMuted);

  static TextStyle bodySmallStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: bodySmall(ctx),
          weight: weight ?? FontWeight.w400,
          color: color ?? AppColors.textLight);

  static TextStyle labelLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: labelLarge(ctx),
          weight: weight ?? FontWeight.w600,
          color: color ?? AppColors.text,
          letterSpacing: 0.1);

  static TextStyle labelSmallStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: labelSmall(ctx),
          weight: weight ?? FontWeight.w500,
          color: color ?? AppColors.textLight,
          letterSpacing: 0.4);

  // ── Master Prompt 126 — hiérarchie officielle du Design System.
  // "Caption"/"Button" n'existaient pas comme noms explicites — alias
  // sémantiques vers les tailles déjà en place (bodySmall/16-SemiBold),
  // aucune nouvelle taille inventée : Display=displayLarge/Medium,
  // Headline=headline, Title=titleLarge/Medium/Small, Body=bodyLarge/Medium,
  // Caption=bodySmall, Button=buttonStyle, Label=labelLarge/Medium/Small.
  static TextStyle captionStyle(BuildContext ctx, {Color? color}) =>
      bodySmallStyle(ctx, color: color);

  /// Style de bouton officiel (16px SemiBold) — identique à celui déjà
  /// appliqué par `ElevatedButtonTheme`/`OutlinedButtonTheme` dans
  /// [AppTheme], exposé ici pour tout composant bouton personnalisé
  /// (ex. `AppButton`) qui ne passe pas par ces thèmes Material.
  static TextStyle buttonStyle(BuildContext ctx, {Color color = Colors.white}) =>
      _build(ctx: ctx, size: _r(ctx, 16), weight: FontWeight.w600, color: color);
}

// ══════════════════════════════════════════════════════════════════════════════
// DIMENSIONS RESPONSIVES
// ══════════════════════════════════════════════════════════════════════════════
class AppLayout {
  AppLayout._();

  /// Facteur d'échelle basé sur la largeur (réf. 390px).
  static double scale(BuildContext context) =>
      (MediaQuery.of(context).size.width / 390.0).clamp(0.78, 1.30);

  /// Valeur responsive avec min/max automatique ± 25%.
  static double r(BuildContext context, double base) =>
      (base * scale(context)).clamp(base * 0.75, base * 1.25);

  /// Fraction de la largeur de l'écran.
  static double wf(BuildContext context, double fraction) =>
      MediaQuery.of(context).size.width * fraction;

  /// Fraction de la hauteur de l'écran.
  static double hf(BuildContext context, double fraction) =>
      MediaQuery.of(context).size.height * fraction;

  static double screenW(BuildContext context) =>
      MediaQuery.of(context).size.width;

  static double screenH(BuildContext context) =>
      MediaQuery.of(context).size.height;

  static double safeBottom(BuildContext context) =>
      MediaQuery.of(context).padding.bottom;

  static double safeTop(BuildContext context) =>
      MediaQuery.of(context).padding.top;

  // ── Breakpoints ──────────────────────────────────────────────────────────
  static bool isSmall(BuildContext context)  => screenW(context) < 360;
  static bool isMedium(BuildContext context) => screenW(context) < 480;
  static bool isLarge(BuildContext context)  => screenW(context) >= 480;

  // ── Espacements responsives ──────────────────────────────────────────────
  static double xs(BuildContext context)  => r(context, 4);
  static double sm(BuildContext context)  => r(context, 8);
  static double md(BuildContext context)  => r(context, 12);
  static double lg(BuildContext context)  => r(context, 16);
  static double xl(BuildContext context)  => r(context, 20);
  static double xxl(BuildContext context) => r(context, 24);
  static double x3l(BuildContext context) => r(context, 32);

  // ── Icônes responsives ───────────────────────────────────────────────────
  static double iconSm(BuildContext context)  => r(context, 16);
  static double iconMd(BuildContext context)  => r(context, 22);
  static double iconLg(BuildContext context)  => r(context, 28);
  static double iconXl(BuildContext context)  => r(context, 36);

  // ── Master Prompt 126 — grille officielle du Design System :
  // 8/12/16/20/24/32/40/48 (sm→x5l). Complète la grille déjà existante
  // (xs=4 conservé pour les micro-espacements déjà utilisés dans l'app,
  // pas retiré pour ne pas casser les call-sites existants) ; x4l/x5l sont
  // purement additifs, aucune valeur déjà utilisée n'a changé.
  static double x4l(BuildContext context) => r(context, 40);
  static double x5l(BuildContext context) => r(context, 48);
}

// ══════════════════════════════════════════════════════════════════════════════
// FORME & RAYON
// ══════════════════════════════════════════════════════════════════════════════
class AppRadius {
  AppRadius._();

  static const double xs    = 6.0;
  static const double sm    = 10.0;
  static const double md    = 14.0;
  static const double lg    = 18.0;
  static const double btn   = 20.0;  // boutons
  static const double input = 18.0;  // champs de saisie (Master Prompt 120)
  static const double card  = 22.0;  // cartes (Master Prompt 120)
  static const double xl    = 24.0;
  static const double xxl   = 32.0;
  static const double pill  = 100.0;

  static const BorderRadius xsR    = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smR    = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdR    = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgR    = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius btnR   = BorderRadius.all(Radius.circular(btn));
  static const BorderRadius inputR = BorderRadius.all(Radius.circular(input));
  static const BorderRadius cardR  = BorderRadius.all(Radius.circular(card));
  static const BorderRadius xlR    = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius xxlR   = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius pillR  = BorderRadius.all(Radius.circular(pill));

  static const BorderRadius topMd  = BorderRadius.vertical(top: Radius.circular(md));
  static const BorderRadius topLg  = BorderRadius.vertical(top: Radius.circular(lg));
  static const BorderRadius topXl  = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius topXxl = BorderRadius.vertical(top: Radius.circular(xxl));

  // ── Master Prompt 126 — système officiel à 3 niveaux (18/22/28) pour tout
  // nouveau composant Design System (`AppButton`/`AppCard`/`EmptyState`...).
  // Ne remplace pas l'échelle fine déjà utilisée par des dizaines d'écrans
  // existants (xs/sm/md/xl/xxl/pill) — la retirer casserait ces écrans sans
  // bénéfice réel, contraire à la règle déjà actée (pas de migration
  // rétroactive non demandée). `official18`/`official22` sont des alias de
  // `lg`/`card` (déjà exactement ces valeurs) ; `official28` est nouveau.
  static const double official18 = lg;   // = 18.0
  static const double official22 = card; // = 22.0
  static const double official28 = 28.0;

  static const BorderRadius official18R = lgR;
  static const BorderRadius official22R = cardR;
  static const BorderRadius official28R =
      BorderRadius.all(Radius.circular(official28));
}

// ══════════════════════════════════════════════════════════════════════════════
// OMBRES
// ══════════════════════════════════════════════════════════════════════════════
class AppShadow {
  AppShadow._();

  // Ombres adoucies (Master Prompt 120) — alpha/blur réduits pour un rendu
  // "très discret" façon Notion/Airbnb plutôt que des ombres marquées.
  static const List<BoxShadow> xs = [
    BoxShadow(color: Color(0x08000000), blurRadius: 6,  offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> sm = [
    BoxShadow(color: Color(0x0A000000), blurRadius: 12, offset: Offset(0, 3)),
    BoxShadow(color: Color(0x06000000), blurRadius: 3,  offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> md = [
    BoxShadow(color: Color(0x0D000000), blurRadius: 22, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x06000000), blurRadius: 6,  offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> lg = [
    BoxShadow(color: Color(0x12000000), blurRadius: 34, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x08000000), blurRadius: 22, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x04000000), blurRadius: 6,  offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> navFloat = [
    BoxShadow(color: Color(0x14000000), blurRadius: 34, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 10, offset: Offset(0, 2)),
  ];

  static List<BoxShadow> colored(Color c, {double opacity = 0.35}) => [
    BoxShadow(
      color:      c.withValues(alpha: opacity),
      blurRadius: 16,
      offset:     const Offset(0, 6),
    ),
  ];
}

// ══════════════════════════════════════════════════════════════════════════════
// TRANSITIONS DE PAGE
// ══════════════════════════════════════════════════════════════════════════════
class AppTransitions {
  AppTransitions._();

  static Route<T> fadeSlide<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder:              (_, __, ___) => page,
      transitionDuration:       const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      transitionsBuilder: (_, anim, __, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end:   Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        );
      },
    );
  }

  static Route<T> slideRight<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder:              (_, __, ___) => page,
      transitionDuration:       const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 250),
      transitionsBuilder: (_, anim, __, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0),
            end:   Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// THÈME GLOBAL — Material Design 3, Urbanist partout, clair + sombre
// (Master Prompt 120)
// ══════════════════════════════════════════════════════════════════════════════
class AppTheme {
  AppTheme._();

  // ── Helper interne : Urbanist partout (Master Prompt 120) ───────────────
  static TextStyle _ts({
    required double   size,
    required FontWeight weight,
    Color?  color,
    double  spacing = 0,
    bool    display = false,
  }) {
    return GoogleFonts.urbanist(
      fontSize:      size,
      fontWeight:    weight,
      color:         color,
      letterSpacing: spacing,
    );
  }

  /// Thème clair — voir [dark] pour l'équivalent sombre (Master Prompt 120),
  /// les deux partagent la même structure via [_build].
  static ThemeData get light => _build(Brightness.light);

  /// Mode sombre (Master Prompt 120) — jamais de noir pur (fonds `slate-900`/
  /// `slate-800`), mêmes couleurs de marque (orange/succès/erreur/info/
  /// avertissement) qu'en clair pour rester reconnaissable, cohérent avec les
  /// apps premium qui gardent leur identité quel que soit le thème actif.
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final bg        = isDark ? AppColors.bgDark        : AppColors.bg;
    final surface    = isDark ? AppColors.cardDark      : AppColors.card;
    final onSurface  = isDark ? AppColors.textDark      : AppColors.text;
    final textMuted  = isDark ? AppColors.textMutedDark : AppColors.textMuted;
    final textLight  = isDark ? AppColors.textLightDark : AppColors.textLight;
    final divider    = isDark ? AppColors.dividerDark   : AppColors.divider;
    final border     = isDark ? AppColors.borderDark    : AppColors.border;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme(
        brightness:              brightness,
        primary:                 AppColors.primary,
        onPrimary:               Colors.white,
        primaryContainer:        isDark ? AppColors.primaryDark : AppColors.primaryBg,
        onPrimaryContainer:      isDark ? AppColors.primaryBg : AppColors.primaryDark,
        secondary:               AppColors.blue,
        onSecondary:             Colors.white,
        surface:                 surface,
        onSurface:               onSurface,
        surfaceContainerHighest: bg,
        error:                   AppColors.red,
        onError:                 Colors.white,
        outline:                 border,
        outlineVariant:          divider,
      ),
      scaffoldBackgroundColor: bg,
    );

    // ── TextTheme M3 — Urbanist partout (Master Prompt 120) ────────────────
    final textTheme = TextTheme(
      displayLarge:   _ts(size: 57, weight: FontWeight.w400, spacing: -0.25, color: onSurface, display: true),
      displayMedium:  _ts(size: 45, weight: FontWeight.w400, color: onSurface, display: true),
      displaySmall:   _ts(size: 36, weight: FontWeight.w400, color: onSurface, display: true),
      headlineLarge:  _ts(size: 32, weight: FontWeight.w700, color: onSurface, display: true),
      headlineMedium: _ts(size: 28, weight: FontWeight.w600, color: onSurface, display: true),
      headlineSmall:  _ts(size: 24, weight: FontWeight.w600, color: onSurface, display: true),
      titleLarge:     _ts(size: 22, weight: FontWeight.w600, color: onSurface),
      titleMedium:    _ts(size: 16, weight: FontWeight.w600, spacing: 0.15, color: onSurface),
      titleSmall:     _ts(size: 14, weight: FontWeight.w600, spacing: 0.10, color: onSurface),
      bodyLarge:      _ts(size: 16, weight: FontWeight.w500, spacing: 0.15, color: onSurface),
      bodyMedium:     _ts(size: 14, weight: FontWeight.w400, spacing: 0.25, color: textMuted),
      bodySmall:      _ts(size: 13, weight: FontWeight.w400, spacing: 0.40, color: textLight),
      labelLarge:     _ts(size: 14, weight: FontWeight.w600, spacing: 0.10, color: onSurface),
      labelMedium:    _ts(size: 12, weight: FontWeight.w500, spacing: 0.50, color: textMuted),
      labelSmall:     _ts(size: 11, weight: FontWeight.w500, spacing: 0.50, color: textLight),
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,

      // ── AppBar ─────────────────────────────────────────────────────────
      appBarTheme: AppBarTheme(
        elevation:              0,
        scrolledUnderElevation: 0,
        centerTitle:            true,
        backgroundColor:        AppColors.primary,
        foregroundColor:        Colors.white,
        systemOverlayStyle:     SystemUiOverlayStyle.light,
        titleTextStyle: _ts(size: 18, weight: FontWeight.w700, color: Colors.white, spacing: 0.1),
        iconTheme: const IconThemeData(color: Colors.white, size: 24),
        actionsIconTheme: const IconThemeData(color: Colors.white, size: 24),
      ),

      // ── Boutons ────────────────────────────────────────────────────────
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return AppColors.primaryDark;
            if (states.contains(WidgetState.disabled)) return AppColors.primary.withValues(alpha: 0.5);
            return AppColors.primary;
          }),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return Colors.black.withValues(alpha: 0.18);
            return null;
          }),
          elevation: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return 0;
            return 2;
          }),
          shadowColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return Colors.transparent;
            return AppColors.primary.withValues(alpha: 0.30);
          }),
          shape: WidgetStateProperty.all(
            const RoundedRectangleBorder(borderRadius: AppRadius.btnR)),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
          textStyle: WidgetStateProperty.all(_ts(size: 16, weight: FontWeight.w600)),
          minimumSize: WidgetStateProperty.all(const Size(64, 54)),
          animationDuration: const Duration(milliseconds: 80),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return AppColors.primaryDark;
            return AppColors.primary;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return AppColors.primary.withValues(alpha: 0.12);
            return null;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return const BorderSide(color: AppColors.primaryDark, width: 2);
            }
            return const BorderSide(color: AppColors.primary, width: 1.5);
          }),
          shape: WidgetStateProperty.all(
            const RoundedRectangleBorder(borderRadius: AppRadius.btnR)),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
          textStyle: WidgetStateProperty.all(_ts(size: 16, weight: FontWeight.w600)),
          minimumSize: WidgetStateProperty.all(const Size(64, 54)),
          animationDuration: const Duration(milliseconds: 80),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return AppColors.primaryDark;
            return AppColors.primary;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return AppColors.primary.withValues(alpha: 0.12);
            return null;
          }),
          textStyle: WidgetStateProperty.all(_ts(size: 14, weight: FontWeight.w600)),
          animationDuration: const Duration(milliseconds: 80),
        ),
      ),

      // ── Champs de saisie ───────────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled:      true,
        fillColor:   surface,
        hintStyle:   _ts(size: 14, weight: FontWeight.w400, color: textLight),
        border:      OutlineInputBorder(
            borderRadius: AppRadius.inputR,
            borderSide: BorderSide(color: border, width: 1)),
        enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.inputR,
            borderSide: BorderSide(color: border, width: 1)),
        focusedBorder: const OutlineInputBorder(
            borderRadius: AppRadius.inputR,
            borderSide: BorderSide(color: AppColors.primary, width: 2)),
        errorBorder: const OutlineInputBorder(
            borderRadius: AppRadius.inputR,
            borderSide: BorderSide(color: AppColors.red, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),

      // ── Cards ──────────────────────────────────────────────────────────
      cardTheme: CardThemeData(
        elevation:   0,
        color:       surface,
        shadowColor: Colors.transparent,
        shape:       const RoundedRectangleBorder(borderRadius: AppRadius.cardR),
        margin:      EdgeInsets.zero,
      ),

      // ── Switch ─────────────────────────────────────────────────────────
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.primary : (isDark ? Colors.grey.shade600 : Colors.grey.shade400),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.primary20 : (isDark ? Colors.grey.shade800 : Colors.grey.shade200),
        ),
      ),

      // ── BottomSheet ────────────────────────────────────────────────────
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape:           const RoundedRectangleBorder(borderRadius: AppRadius.topXxl),
      ),

      // ── Snackbar ───────────────────────────────────────────────────────
      snackBarTheme: SnackBarThemeData(
        behavior:         SnackBarBehavior.floating,
        backgroundColor:  isDark ? AppColors.cardDark : AppColors.text,
        contentTextStyle: _ts(size: 13, weight: FontWeight.w400, color: Colors.white),
        shape:            const RoundedRectangleBorder(borderRadius: AppRadius.mdR),
      ),

      // ── Dialog ─────────────────────────────────────────────────────────
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation:       0,
        shape:           const RoundedRectangleBorder(borderRadius: AppRadius.cardR),
      ),

      // ── Divider ────────────────────────────────────────────────────────
      dividerTheme: DividerThemeData(
        color: divider, thickness: 1, space: 1),

      // ── Chip ───────────────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        shape:           const StadiumBorder(),
        padding:         const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        labelStyle:      _ts(size: 12, weight: FontWeight.w600),
        backgroundColor: bg,
      ),

      // ── Page Transitions ───────────────────────────────────────────────
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS:     ZoomPageTransitionsBuilder(),
        },
      ),

      splashFactory: InkRipple.splashFactory,
    );
  }
}
