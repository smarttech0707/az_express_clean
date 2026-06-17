import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Brand colors (identiques à AppColors dans app_theme.dart) ────────────────
const kOrange    = Color(0xFFFF6D00);  // AppColors.primary
const kOrangeL   = Color(0xFFFF8F00);  // AppColors.primaryLight
const kOrangeD   = Color(0xFFE55A00);
const kOrangeBg  = Color(0xFFFFF3E0);  // AppColors.primaryBg
const kBlue      = Color(0xFF1565C0);  // AppColors.blue
const kBlueL     = Color(0xFF1E88E5);  // AppColors.blueLight
const kSuccess   = Color(0xFF2E7D32);  // AppColors.green
const kText      = Color(0xFF1A1A2E);  // AppColors.text
const kTextGrey  = Color(0xFF666666);  // AppColors.textGrey
const kTextMuted = Color(0xFF666666);

// ── Light theme backgrounds (identiques à l'app mobile) ───────────────────────
const kBg        = Color(0xFFF0F2F5);  // AppColors.bg
const kCard      = Color(0xFFFFFFFF);  // AppColors.card
const kDivider   = Color(0xFFEEEEEE);  // AppColors.divider
const kWhite     = Color(0xFFFFFFFF);

// ── Aliases pour compatibilité avec le code existant ─────────────────────────
const kNavy      = kBg;       // fond clair
const kNavyDark  = kCard;     // section blanche
const kNavyMid   = kBg;       // section gris clair
const kNavyCard  = kCard;     // cards blanches

// ── Gradients ─────────────────────────────────────────────────────────────────
const kHeroGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [kOrangeD, kOrange, kOrangeL],
);

const kOrangeGradient = LinearGradient(
  colors: [kOrange, kOrangeL],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const kBlueGradient = LinearGradient(
  colors: [kBlue, kBlueL],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

// ── Responsive helpers ────────────────────────────────────────────────────────
bool isDesktop(BuildContext ctx) => MediaQuery.of(ctx).size.width >= 1024;
bool isTablet(BuildContext ctx)  => MediaQuery.of(ctx).size.width >= 600;
bool isMobile(BuildContext ctx)  => MediaQuery.of(ctx).size.width < 600;

double hPad(BuildContext ctx) {
  final w = MediaQuery.of(ctx).size.width;
  if (w >= 1280) return 140;
  if (w >= 1024) return 80;
  if (w >= 600)  return 40;
  return 20;
}

// ── Typography ────────────────────────────────────────────────────────────────
TextStyle kDisplayStyle(BuildContext ctx) => GoogleFonts.inter(
  fontSize: isDesktop(ctx) ? 60 : (isTablet(ctx) ? 44 : 34),
  fontWeight: FontWeight.w800,
  color: kWhite,         // sur fond orange hero = blanc
  height: 1.1,
  letterSpacing: -1.0,
);

TextStyle kH1Style(BuildContext ctx) => GoogleFonts.inter(
  fontSize: isDesktop(ctx) ? 40 : 26,
  fontWeight: FontWeight.w700,
  color: kText,          // sur fond clair = texte sombre
  height: 1.2,
);

TextStyle kH2Style(BuildContext ctx) => GoogleFonts.inter(
  fontSize: isDesktop(ctx) ? 28 : 20,
  fontWeight: FontWeight.w600,
  color: kText,
  height: 1.25,
);

TextStyle kBodyStyle({Color color = kTextMuted, double size = 16}) =>
    GoogleFonts.inter(fontSize: size, fontWeight: FontWeight.w400, color: color, height: 1.7);

TextStyle kLabelStyle({Color color = kText}) =>
    GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: color, letterSpacing: 0.5);

// ── Shared decorations ────────────────────────────────────────────────────────
BoxDecoration glassCard({double radius = 20, Color? border}) => BoxDecoration(
  color: kCard,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: border ?? kDivider, width: 1),
  boxShadow: const [
    BoxShadow(color: Color(0x0A000000), blurRadius: 12, offset: Offset(0, 4)),
  ],
);

BoxDecoration orangeGlowDecoration = BoxDecoration(
  gradient: kOrangeGradient,
  borderRadius: BorderRadius.circular(16),
  boxShadow: [BoxShadow(
    color: kOrange.withValues(alpha: 0.35),
    blurRadius: 20,
    offset: const Offset(0, 6),
  )],
);
