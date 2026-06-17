import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Détection plateforme ─────────────────────────────────────────────────────
// SF Pro n'est disponible qu'en tant que police système iOS/macOS.
// On ne peut pas la bundler — Flutter l'appelle via son nom interne.
bool get _isApple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

// SF Pro Display → grandes tailles (Display, Headline)
const String _sfProDisplay = '.SF Pro Display';
// SF Pro Text    → corps, labels, boutons
const String _sfProText    = '.SF Pro Text';

// ══════════════════════════════════════════════════════════════════════════════
// COULEURS — AZ Express Brand
// ══════════════════════════════════════════════════════════════════════════════
class AppColors {
  AppColors._();

  static const primary      = Color(0xFFFF6B00);
  static const primaryLight = Color(0xFFFF8C42);
  static const primaryDark  = Color(0xFFE65100);
  static const primaryBg    = Color(0xFFFFF3E0);

  static const primary05 = Color(0x0DFF6B00);
  static const primary08 = Color(0x14FF6B00);
  static const primary10 = Color(0x1AFF6B00);
  static const primary15 = Color(0x26FF6B00);
  static const primary20 = Color(0x33FF6B00);
  static const primary35 = Color(0x59FF6B00);

  static const blue      = Color(0xFF1565C0);
  static const blueDark  = Color(0xFF0D47A1);
  static const blueLight = Color(0xFF1E88E5);
  static const blueBg    = Color(0xFFE3F2FD);

  static const blue05 = Color(0x0D1565C0);
  static const blue10 = Color(0x1A1565C0);
  static const blue15 = Color(0x261565C0);
  static const blue20 = Color(0x331565C0);
  static const blue40 = Color(0x661565C0);

  static const green    = Color(0xFF2E7D32);
  static const greenBg  = Color(0xFFE8F5E9);
  static const green10  = Color(0x1A2E7D32);

  static const purple   = Color(0xFF6A1B9A);
  static const purpleBg = Color(0xFFF3E5F5);

  static const red   = Color(0xFFC62828);
  static const redBg = Color(0xFFFFEBEE);

  static const bg       = Color(0xFFF8F9FB);
  static const bgLight  = Color(0xFFFCFCFE);
  static const card     = Color(0xFFFFFFFF);
  static const text     = Color(0xFF0F172A);
  static const textMuted = Color(0xFF64748B);
  static const textLight = Color(0xFF94A3B8);
  static const divider  = Color(0xFFE2E8F0);
  static const border   = Color(0xFFCBD5E1);

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
}

// ══════════════════════════════════════════════════════════════════════════════
// SYSTÈME TYPOGRAPHIQUE RESPONSIVE
// iOS  → SF Pro Display (titres) / SF Pro Text (corps)
// Android / Web → Inter (Google Fonts)
// ══════════════════════════════════════════════════════════════════════════════
class AppTypography {
  AppTypography._();

  // ── Scale responsive (réf. 390px = iPhone 14) ──────────────────────────
  static double _scale(BuildContext context) =>
      (MediaQuery.of(context).size.width / 390.0).clamp(0.78, 1.30);

  static double _r(BuildContext context, double base) =>
      (base * _scale(context)).roundToDouble();

  // ── Tailles ─────────────────────────────────────────────────────────────
  static double displayLarge(BuildContext ctx)  => _r(ctx, 34);
  static double displayMedium(BuildContext ctx) => _r(ctx, 28);
  static double headline(BuildContext ctx)      => _r(ctx, 22);
  static double titleLarge(BuildContext ctx)    => _r(ctx, 18);
  static double titleMedium(BuildContext ctx)   => _r(ctx, 16);
  static double titleSmall(BuildContext ctx)    => _r(ctx, 14);
  static double bodyLarge(BuildContext ctx)     => _r(ctx, 15);
  static double bodyMedium(BuildContext ctx)    => _r(ctx, 13);
  static double bodySmall(BuildContext ctx)     => _r(ctx, 12);
  static double labelLarge(BuildContext ctx)    => _r(ctx, 13);
  static double labelMedium(BuildContext ctx)   => _r(ctx, 12);
  static double labelSmall(BuildContext ctx)    => _r(ctx, 11);

  // ── Constructeur de style platform-aware ────────────────────────────────
  // [display] → SF Pro Display / Inter Bold  (Display, Headline)
  // [!display] → SF Pro Text / Inter         (Title, Body, Label)
  static TextStyle _build({
    required BuildContext ctx,
    required double size,
    required FontWeight weight,
    Color? color,
    double letterSpacing = 0,
    bool display = false,       // true → grandes tailles (Display/Headline)
  }) {
    if (_isApple) {
      return TextStyle(
        fontFamily:    display ? _sfProDisplay : _sfProText,
        fontSize:      size,
        fontWeight:    weight,
        color:         color,
        letterSpacing: letterSpacing,
        decoration:    TextDecoration.none,
      );
    }
    return GoogleFonts.poppins(
      fontSize:      size,
      fontWeight:    weight,
      color:         color,
      letterSpacing: letterSpacing,
    );
  }

  // ── Styles complets ──────────────────────────────────────────────────────
  static TextStyle displayLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: displayLarge(ctx),
          weight: weight ?? FontWeight.w800,
          color: color ?? AppColors.text,
          letterSpacing: -0.5, display: true);

  static TextStyle displayMediumStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: displayMedium(ctx),
          weight: weight ?? FontWeight.w700,
          color: color ?? AppColors.text,
          letterSpacing: -0.3, display: true);

  static TextStyle headlineStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: headline(ctx),
          weight: weight ?? FontWeight.w700,
          color: color ?? AppColors.text,
          display: true);

  static TextStyle titleLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: titleLarge(ctx),
          weight: weight ?? FontWeight.w700,
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

  static TextStyle bodyLargeStyle(BuildContext ctx,
          {Color? color, FontWeight? weight}) =>
      _build(ctx: ctx, size: bodyLarge(ctx),
          weight: weight ?? FontWeight.w400,
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
}

// ══════════════════════════════════════════════════════════════════════════════
// FORME & RAYON
// ══════════════════════════════════════════════════════════════════════════════
class AppRadius {
  AppRadius._();

  static const double xs   = 6.0;
  static const double sm   = 10.0;
  static const double md   = 14.0;
  static const double lg   = 18.0;
  static const double btn  = 20.0;  // boutons & inputs
  static const double xl   = 24.0;
  static const double xxl  = 32.0;
  static const double pill = 100.0;

  static const BorderRadius xsR   = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smR   = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdR   = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgR   = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius btnR  = BorderRadius.all(Radius.circular(btn));
  static const BorderRadius xlR   = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius xxlR  = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius pillR = BorderRadius.all(Radius.circular(pill));

  static const BorderRadius topMd  = BorderRadius.vertical(top: Radius.circular(md));
  static const BorderRadius topLg  = BorderRadius.vertical(top: Radius.circular(lg));
  static const BorderRadius topXl  = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius topXxl = BorderRadius.vertical(top: Radius.circular(xxl));
}

// ══════════════════════════════════════════════════════════════════════════════
// OMBRES
// ══════════════════════════════════════════════════════════════════════════════
class AppShadow {
  AppShadow._();

  static const List<BoxShadow> xs = [
    BoxShadow(color: AppColors.black05, blurRadius: 6,  offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> sm = [
    BoxShadow(color: AppColors.black08, blurRadius: 12, offset: Offset(0, 3)),
    BoxShadow(color: AppColors.black05, blurRadius: 3,  offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> md = [
    BoxShadow(color: AppColors.black10, blurRadius: 20, offset: Offset(0, 6)),
    BoxShadow(color: AppColors.black05, blurRadius: 6,  offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> lg = [
    BoxShadow(color: AppColors.black12, blurRadius: 32, offset: Offset(0, 10)),
    BoxShadow(color: AppColors.black08, blurRadius: 10, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0A000000), blurRadius: 20, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x06000000), blurRadius: 6,  offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> navFloat = [
    BoxShadow(color: AppColors.black15, blurRadius: 32, offset: Offset(0, 8)),
    BoxShadow(color: AppColors.black08, blurRadius: 10, offset: Offset(0, 2)),
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
// THÈME GLOBAL — Material Design 3
// iOS → SF Pro Display / SF Pro Text
// Android / Web → Inter
// ══════════════════════════════════════════════════════════════════════════════
class AppTheme {
  AppTheme._();

  // ── Helper interne : construit un TextStyle platform-aware ──────────────
  static TextStyle _ts({
    required double   size,
    required FontWeight weight,
    Color?  color,
    double  spacing = 0,
    bool    display = false, // SF Pro Display vs Text
  }) {
    if (_isApple) {
      return TextStyle(
        fontFamily:    display ? _sfProDisplay : _sfProText,
        fontSize:      size,
        fontWeight:    weight,
        color:         color,
        letterSpacing: spacing,
      );
    }
    return GoogleFonts.poppins(
      fontSize:      size,
      fontWeight:    weight,
      color:         color,
      letterSpacing: spacing,
    );
  }

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary:                 AppColors.primary,
        onPrimary:               Colors.white,
        primaryContainer:        AppColors.primaryBg,
        onPrimaryContainer:      AppColors.primaryDark,
        secondary:               AppColors.blue,
        onSecondary:             Colors.white,
        surface:                 AppColors.card,
        onSurface:               AppColors.text,
        surfaceContainerHighest: AppColors.bg,
        error:                   AppColors.red,
        onError:                 Colors.white,
        outline:                 AppColors.border,
        outlineVariant:          AppColors.divider,
      ),
      scaffoldBackgroundColor: AppColors.bg,
    );

    // ── TextTheme M3 platform-aware ────────────────────────────────────────
    // Grandes tailles (Display, Headline) → SF Pro Display / Inter Bold
    // Corps et labels → SF Pro Text / Inter
    final textTheme = TextTheme(
      displayLarge:   _ts(size: 57, weight: FontWeight.w400, spacing: -0.25, color: AppColors.text, display: true),
      displayMedium:  _ts(size: 45, weight: FontWeight.w400, color: AppColors.text, display: true),
      displaySmall:   _ts(size: 36, weight: FontWeight.w400, color: AppColors.text, display: true),
      headlineLarge:  _ts(size: 32, weight: FontWeight.w700, color: AppColors.text, display: true),
      headlineMedium: _ts(size: 28, weight: FontWeight.w600, color: AppColors.text, display: true),
      headlineSmall:  _ts(size: 24, weight: FontWeight.w600, color: AppColors.text, display: true),
      titleLarge:     _ts(size: 22, weight: FontWeight.w700, color: AppColors.text),
      titleMedium:    _ts(size: 16, weight: FontWeight.w600, spacing: 0.15, color: AppColors.text),
      titleSmall:     _ts(size: 14, weight: FontWeight.w600, spacing: 0.10, color: AppColors.text),
      bodyLarge:      _ts(size: 16, weight: FontWeight.w400, spacing: 0.15, color: AppColors.text),
      bodyMedium:     _ts(size: 14, weight: FontWeight.w400, spacing: 0.25, color: AppColors.textMuted),
      bodySmall:      _ts(size: 12, weight: FontWeight.w400, spacing: 0.40, color: AppColors.textLight),
      labelLarge:     _ts(size: 14, weight: FontWeight.w600, spacing: 0.10, color: AppColors.text),
      labelMedium:    _ts(size: 12, weight: FontWeight.w500, spacing: 0.50, color: AppColors.textMuted),
      labelSmall:     _ts(size: 11, weight: FontWeight.w500, spacing: 0.50, color: AppColors.textLight),
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
          textStyle: WidgetStateProperty.all(_ts(size: 16, weight: FontWeight.w700)),
          minimumSize: WidgetStateProperty.all(const Size(64, 52)),
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
          minimumSize: WidgetStateProperty.all(const Size(64, 52)),
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
        fillColor:   AppColors.card,
        hintStyle:   _ts(size: 14, weight: FontWeight.w400, color: AppColors.textLight),
        border:      const OutlineInputBorder(
            borderRadius: AppRadius.btnR,
            borderSide: BorderSide(color: AppColors.border, width: 1)),
        enabledBorder: const OutlineInputBorder(
            borderRadius: AppRadius.btnR,
            borderSide: BorderSide(color: AppColors.border, width: 1)),
        focusedBorder: const OutlineInputBorder(
            borderRadius: AppRadius.btnR,
            borderSide: BorderSide(color: AppColors.primary, width: 2)),
        errorBorder: const OutlineInputBorder(
            borderRadius: AppRadius.btnR,
            borderSide: BorderSide(color: AppColors.red, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),

      // ── Cards ──────────────────────────────────────────────────────────
      cardTheme: const CardThemeData(
        elevation:   0,
        color:       AppColors.card,
        shadowColor: Colors.transparent,
        shape:       RoundedRectangleBorder(borderRadius: AppRadius.xlR),
        margin:      EdgeInsets.zero,
      ),

      // ── Switch ─────────────────────────────────────────────────────────
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.primary : Colors.grey.shade400,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.primary20 : Colors.grey.shade200,
        ),
      ),

      // ── BottomSheet ────────────────────────────────────────────────────
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.card,
        shape:           RoundedRectangleBorder(borderRadius: AppRadius.topXxl),
      ),

      // ── Snackbar ───────────────────────────────────────────────────────
      snackBarTheme: SnackBarThemeData(
        behavior:         SnackBarBehavior.floating,
        backgroundColor:  AppColors.text,
        contentTextStyle: _ts(size: 13, weight: FontWeight.w400, color: Colors.white),
        shape:            const RoundedRectangleBorder(borderRadius: AppRadius.mdR),
      ),

      // ── Dialog ─────────────────────────────────────────────────────────
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.card,
        elevation:       0,
        shape:           RoundedRectangleBorder(borderRadius: AppRadius.xlR),
      ),

      // ── Divider ────────────────────────────────────────────────────────
      dividerTheme: const DividerThemeData(
        color: AppColors.divider, thickness: 1, space: 1),

      // ── Chip ───────────────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        shape:           const StadiumBorder(),
        padding:         const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        labelStyle:      _ts(size: 12, weight: FontWeight.w600),
        backgroundColor: AppColors.bg,
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
