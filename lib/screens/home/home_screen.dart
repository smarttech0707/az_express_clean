import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../l10n/app_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/tap_effect.dart';
import '../../widgets/premium_background.dart';
import '../../widgets/app_card.dart';
import '../../widgets/glass_kit.dart';
import '../../services/notification_service.dart';
import '../admin/admin_login.dart';
import '../main_dashboard.dart';
import '../auth/client_auth_page.dart';
import '../seller/seller_dashboard.dart';
import '../pro/pro_portal.dart';
import '../support/support_screen.dart';
import '../../ekbine/screens/ek_home_screen.dart';

// LOT 3 Premium V1 (pilote) — refonte visuelle uniquement. Aucune navigation,
// aucune logique de connexion/permissions/Firebase n'a été modifiée dans ce
// fichier : chaque méthode ci-dessous (`_onLogoTap`, `_onProTap`,
// `_showSOSConfirm`, `_sendSOS`, `_goToDashboard`) est restée identique à
// l'avant-LOT 3 — seul l'habillage visuel des widgets construits par
// `build()` a changé.

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _tapCount = 0;
  Timer? _tapTimer;
  int _proTapCount = 0;
  Timer? _proTapTimer;
  bool _sosSent = false;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _entryCtrl;
  late List<Animation<double>> _cardAnims;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(const AssetImage('assets/logo.png'), context)
        .catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    _pulseCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.06)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _entryCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000));
    _cardAnims = List.generate(2, (i) {
      final start = i * 0.12;
      final end = (start + 0.65).clamp(0.0, 1.0);
      return CurvedAnimation(
          parent: _entryCtrl,
          curve: Interval(start, end, curve: Curves.easeOutBack));
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _entryCtrl.forward();
    });
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _proTapTimer?.cancel();
    _pulseCtrl.dispose();
    _entryCtrl.dispose();
    super.dispose();
  }

  void _onLogoTap() {
    _tapTimer?.cancel();
    if (++_tapCount >= 5) {
      _tapCount = 0;
      Navigator.push(context, AppTransitions.fadeSlide(const AdminLogin()));
      return;
    }
    _tapTimer = Timer(const Duration(seconds: 2), () => _tapCount = 0);
  }

  void _onProTap() {
    _proTapTimer?.cancel();
    if (++_proTapCount >= 3) {
      _proTapCount = 0;
      Navigator.push(context, AppTransitions.fadeSlide(const ProPortal()));
      return;
    }
    _proTapTimer = Timer(const Duration(seconds: 2), () => _proTapCount = 0);
  }

  void _showSOSConfirm() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      Navigator.push(context, AppTransitions.fadeSlide(const ClientAuthPage()));
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.xlR),
        title: const Row(children: [
          Icon(Icons.sos_rounded, color: Colors.red, size: 24),
          SizedBox(width: 8),
          Text('Alerte SOS',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        ]),
        content: const Text(
          'Envoyer une alerte d\'urgence à l\'équipe AZ Express avec votre position GPS ?',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          ScaleButton(
            onPressed: () {
              Navigator.pop(context);
              _sendSOS();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdR),
            ),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendSOS() async {
    setState(() => _sosSent = true);
    double lat = 0, lng = 0;
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 6));
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {}

    if (lat == 0 || lng == 0) {
      if (mounted) {
        setState(() => _sosSent = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📍 GPS indisponible. Activez le GPS et réessayez.'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    String clientName = 'Client';
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients')
          .doc(user?.uid ?? '')
          .get();
      clientName = doc.data()?['name'] ?? 'Client';
    } catch (_) {}

    await FirebaseFirestore.instance.collection('sos_alerts').add({
      'clientId': user?.uid ?? '',
      'clientName': clientName,
      'type': 'client',
      'lat': lat,
      'lng': lng,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'active',
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('🚨 Alerte SOS envoyée ! L\'équipe va vous contacter.'),
      backgroundColor: Colors.red,
      duration: Duration(seconds: 4),
    ));
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) setState(() => _sosSent = false);
    });
  }

  Future<void> _goToDashboard() async {
    final user = FirebaseAuth.instance.currentUser;
    final isAnon = user == null || user.isAnonymous;
    if (isAnon) {
      Navigator.push(context, AppTransitions.fadeSlide(const ClientAuthPage()));
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('sellers')
          .doc(user.uid)
          .get();
      if (!mounted) return;
      if (doc.exists && (doc.data()?['isActive'] ?? false)) {
        // Master Prompt 128 (Partie 11) — ce chemin de reprise automatique
        // de session ne rafraîchissait jamais le jeton FCM (contrairement
        // à chaque écran de connexion manuelle), risquant des notifications
        // non délivrées après un long moment sans relancer l'app via un
        // vrai formulaire de connexion.
        NotificationService().saveToken(user.uid, 'sellers');
        Navigator.push(
            context,
            AppTransitions.fadeSlide(
                SellerDashboard(sellerId: user.uid, sellerData: doc.data()!)));
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || currentUser.isAnonymous) {
      Navigator.push(context, AppTransitions.fadeSlide(const ClientAuthPage()));
      return;
    }
    NotificationService().saveToken(currentUser.uid, 'clients');
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MainDashboard()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final language = AppLanguage.of(context);
    final text = AppText(language.locale);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final exit = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.xlR),
            title: const Text('Quitter AZ Express ?'),
            content: const Text('Voulez-vous fermer l\'application ?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Non'),
              ),
              ScaleButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Oui'),
              ),
            ],
          ),
        );
        if (exit == true && context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // LOT 3 — le fond n'est plus un orange plein (icônes système
        // toujours claires) : la teinte de la barre système suit désormais
        // le thème actif, comme un vrai fond blanc cassé / bleu nuit.
        value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: Scaffold(
          body: PremiumBackground(
            child: SafeArea(
              child: CustomScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  // ── TOP BAR ───────────────────────────────────────────────
                  SliverToBoxAdapter(
                    child: _TopBar(
                      text: text,
                      language: language,
                      sosSent: _sosSent,
                      onSOS: _sosSent ? null : _showSOSConfirm,
                      onPro: _onProTap,
                    ),
                  ),

                  // ── HERO ──────────────────────────────────────────────────
                  SliverToBoxAdapter(
                    child: GestureDetector(
                      onTap: _onLogoTap,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          AppLayout.xl(context),
                          AppLayout.xs(context),
                          AppLayout.xl(context),
                          AppLayout.lg(context),
                        ),
                        child: _HeroSection(
                          text: text,
                          pulseAnim: _pulseAnim,
                        ),
                      ),
                    ),
                  ),

                  // ── CARTES SERVICES ───────────────────────────────────────
                  SliverToBoxAdapter(
                    child: _CardsSection(
                      text: text,
                      cardAnims: _cardAnims,
                      onOrder: _goToDashboard,
                      onEkbine: () => Navigator.push(context,
                          AppTransitions.fadeSlide(const EkHomeScreen())),
                      onPro: () => Navigator.push(
                          context, AppTransitions.fadeSlide(const ProPortal())),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP BAR — LOT 3 : couleurs premium (plus de blanc en dur sur fond orange),
// wordmark en accent orange, chips theme-aware.
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final AppText text;
  final AppLanguage language;
  final bool sosSent;
  final VoidCallback? onSOS;
  final VoidCallback onPro;

  const _TopBar({
    required this.text,
    required this.language,
    required this.sosSent,
    required this.onSOS,
    required this.onPro,
  });

  @override
  Widget build(BuildContext context) {
    final hPad = AppLayout.xl(context);
    final vPad = AppLayout.md(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      child: Row(
        children: [
          GestureDetector(
            onTap: onPro,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'AZ EXPRESS',
                  style: GoogleFonts.urbanist(
                    // Petit accent orange (marque) plutôt qu'un fond orange
                    // plein — cohérent avec "orange = accent principal".
                    color: AppColors.primary,
                    fontSize: AppTypography.titleLarge(context),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          _SosChip(sent: sosSent, onTap: onSOS),
          SizedBox(width: AppLayout.sm(context)),
          _LangButton(text: text, language: language),
        ],
      ),
    );
  }
}

class _SosChip extends StatelessWidget {
  final bool sent;
  final VoidCallback? onTap;
  const _SosChip({required this.sent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mutedText = isDark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    final color = sent ? mutedText : AppColors.error;
    final hPad = AppLayout.md(context);
    final vPad = AppLayout.xs(context) + 3;
    final iconSz = AppLayout.iconSm(context);
    final txtSz = AppTypography.labelMedium(context);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.16 : 0.10),
          borderRadius: AppRadius.pillR,
          border: Border.all(color: color.withValues(alpha: 0.35), width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sos_rounded, color: color, size: iconSz),
            SizedBox(width: AppLayout.xs(context) + 1),
            Text(
              sent ? 'Envoyé' : 'SOS',
              style: GoogleFonts.urbanist(
                color: color,
                fontSize: txtSz,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LangButton extends StatelessWidget {
  final AppText text;
  final AppLanguage language;
  const _LangButton({required this.text, required this.language});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final surface = AppColors.premiumSurface(brightness);
    final border = AppColors.premiumBorder(brightness);
    final iconColor = isDark
        ? AppColors.premiumTextSecondaryDark
        : AppColors.premiumTextSecondaryLight;
    final btnSz = AppLayout.r(context, 36);
    final iconSz = AppLayout.iconSm(context) + 2;

    return PopupMenuButton<String>(
      icon: Container(
        width: btnSz,
        height: btnSz,
        decoration: BoxDecoration(
          color: surface,
          shape: BoxShape.circle,
          border: Border.all(color: border),
          boxShadow: AppShadow.xs,
        ),
        child: Icon(Icons.language_rounded, color: iconColor, size: iconSz),
      ),
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.lgR),
      elevation: 4,
      onSelected: (code) => language.onLocaleChanged(Locale(code)),
      itemBuilder: (_) => [
        PopupMenuItem(
            value: 'fr',
            child: Text('Français', style: GoogleFonts.urbanist())),
        PopupMenuItem(
            value: 'en', child: Text('English', style: GoogleFonts.urbanist())),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HERO — LOT 3 : médaillon logo + halo très discret + texte hiérarchisé,
// theme-aware (aucun texte blanc en dur sur un fond qui n'est plus orange).
// 100% responsive, aucune taille fixe.
// ─────────────────────────────────────────────────────────────────────────────
class _HeroSection extends StatelessWidget {
  final AppText text;
  final Animation<double> pulseAnim;
  const _HeroSection({required this.text, required this.pulseAnim});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.premiumTextPrimaryDark
        : AppColors.premiumTextPrimaryLight;

    // Logo = 22% de la hauteur d'écran, borné entre 110 et 180
    final logoSz = AppLayout.hf(context, 0.165).clamp(88.0, 136.0);
    final haloSz = logoSz * 1.48;

    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('home-hero-ambient-halo'),
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.42),
                  radius: 0.82,
                  colors: [
                    AppColors.primary.withValues(alpha: isDark ? 0.055 : 0.040),
                    AppColors.primary.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Médaillon logo + halo très discret (dégradé radial, jamais animé
            // séparément — seul le médaillon pulse déjà).
            SizedBox(
              width: logoSz,
              height: logoSz,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: (logoSz - haloSz) / 2,
                    top: (logoSz - haloSz) / 2,
                    child: Container(
                      width: haloSz,
                      height: haloSz,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            AppColors.primary
                                .withValues(alpha: isDark ? 0.12 : 0.07),
                            AppColors.primary.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: pulseAnim,
                    builder: (_, child) =>
                        Transform.scale(scale: pulseAnim.value, child: child),
                    child: Container(
                      width: logoSz,
                      height: logoSz,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: AppColors.primary
                              .withValues(alpha: isDark ? 0.18 : 0.12),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: isDark ? 0.18 : 0.07),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                          BoxShadow(
                            color: AppColors.primary
                                .withValues(alpha: isDark ? 0.16 : 0.10),
                            blurRadius: 10,
                            spreadRadius: -2,
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(logoSz * 0.08),
                        child: Image.asset(
                          'assets/logo.png',
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.delivery_dining,
                            color: AppColors.primary,
                            size: logoSz * 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: AppLayout.md(context)),

            // Titre — texte hiérarchisé (theme-aware, ni blanc ni noir en dur).
            Text(
              text.t('welcome'),
              textAlign: TextAlign.center,
              style: AppTypography.headlineStyle(context,
                  color: textPrimary, weight: FontWeight.w600),
            ),

            SizedBox(height: AppLayout.sm(context) + 2),

            // Badge localisation — accent orange discret.
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: AppLayout.md(context),
                vertical: AppLayout.xs(context) + 2,
              ),
              decoration: BoxDecoration(
                color:
                    AppColors.primary.withValues(alpha: isDark ? 0.14 : 0.08),
                borderRadius: AppRadius.pillR,
                border: Border.all(
                    color: AppColors.primary
                        .withValues(alpha: isDark ? 0.34 : 0.22)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on_rounded,
                      color: AppColors.primary,
                      size: AppLayout.iconSm(context)),
                  SizedBox(width: AppLayout.xs(context) + 1),
                  Flexible(
                    child: Text(
                      'Abengourou & environs',
                      style: AppTypography.labelLargeStyle(context,
                          color: AppColors.primary, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION CARTES — LOT 3 : plus de panneau gris plein écran (l'arrière-plan
// est désormais `PremiumBackground` sur toute la page) — les cartes
// premium reposent directement dessus. Livraison/Courses (carte
// "Commander") reste visuellement prioritaire (AppCard.elevated + glow).
// ─────────────────────────────────────────────────────────────────────────────
class _CardsSection extends StatelessWidget {
  final AppText text;
  final List<Animation<double>> cardAnims;
  final VoidCallback onOrder;
  final VoidCallback onEkbine;
  final VoidCallback onPro;

  const _CardsSection({
    required this.text,
    required this.cardAnims,
    required this.onOrder,
    required this.onEkbine,
    required this.onPro,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.premiumTextPrimaryDark
        : AppColors.premiumTextPrimaryLight;
    final textMuted = isDark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    final hPad = AppLayout.xl(context);
    final vBottom = AppLayout.safeBottom(context) + AppLayout.lg(context);

    final cards = [
      // Livraison/Courses (point d'entrée "Commander") — priorité visuelle
      // explicite demandée par le brief : carte élevée (glow), en premier.
      _CardData(
        title: text.t('order'),
        subtitle: text.t('fast_delivery'),
        icon: Icons.shopping_bag_rounded,
        badge: '🚀 Express',
        accent: AppColors.primary,
        priority: true,
        onTap: onOrder,
      ),
      // E-Kbine garde son identité de sous-marque (vert/teal) — jamais
      // écrasée par l'orange principal (déjà acté ailleurs dans le projet).
      _CardData(
        title: 'E-Kbine Services',
        subtitle: 'Crédit · Internet · Mobile Money',
        icon: Icons.sim_card_rounded,
        badge: '⚡ Instantané',
        accent: const Color(0xFF00897B),
        priority: false,
        onTap: onEkbine,
      ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, vBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AzDivider(),
          SizedBox(height: AppLayout.md(context)),

          // Titre section
          Row(
            children: [
              Expanded(
                child: Text('Nos services',
                    style: AppTypography.titleLargeStyle(context,
                        color: textPrimary, weight: FontWeight.w700)),
              ),
              SizedBox(width: AppLayout.sm(context)),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: AppLayout.sm(context) + 2,
                  vertical: AppLayout.xs(context),
                ),
                decoration: BoxDecoration(
                  color:
                      AppColors.primary.withValues(alpha: isDark ? 0.10 : 0.06),
                  borderRadius: AppRadius.pillR,
                ),
                child: Text('Abengourou',
                    style: AppTypography.labelSmallStyle(context,
                        color: AppColors.primary, weight: FontWeight.w600)),
              ),
            ],
          ),

          SizedBox(height: AppLayout.lg(context)),

          // Cartes animées
          ...cards.asMap().entries.map((e) {
            return Padding(
              padding: EdgeInsets.only(
                  top: e.key == 0 ? 0 : AppLayout.sm(context) + 4),
              child: FadeTransition(
                opacity: cardAnims[e.key],
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.3),
                    end: Offset.zero,
                  ).animate(cardAnims[e.key]),
                  child: _ServiceCard(data: e.value),
                ),
              ),
            );
          }),

          SizedBox(height: AppLayout.lg(context)),

          // Bouton Support
          TapEffect(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SupportScreen()),
            ),
            scaleDown: 0.97,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: AppLayout.md(context)),
              decoration: BoxDecoration(
                color:
                    AppColors.primary.withValues(alpha: isDark ? 0.12 : 0.06),
                borderRadius: AppRadius.premiumLgR,
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.22)),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppLayout.xs(context) + 2,
                children: [
                  Icon(Icons.support_agent_rounded,
                      size: AppLayout.iconSm(context),
                      color: AppColors.primary),
                  Text(
                    'Aide & Support',
                    style: AppTypography.labelLargeStyle(context,
                        color: AppColors.primary, weight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(height: AppLayout.sm(context) + 2),

          // Bouton Espace Pro
          TapEffect(
            onTap: onPro,
            scaleDown: 0.97,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                vertical: AppLayout.md(context),
              ),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: AppRadius.premiumLgR,
                border: Border.all(color: AppColors.premiumBorder(brightness)),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppLayout.xs(context) + 2,
                children: [
                  Icon(Icons.business_center_rounded,
                      size: AppLayout.iconSm(context), color: textMuted),
                  Text(
                    'Espace Professionnel',
                    style: AppTypography.labelLargeStyle(context,
                        color: textMuted, weight: FontWeight.w600),
                  ),
                  Icon(Icons.arrow_forward_ios_rounded,
                      size: AppLayout.iconSm(context) - 4, color: textMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardData {
  final String title;
  final String subtitle;
  final IconData icon;
  final String badge;
  final Color accent;
  final bool priority;
  final VoidCallback onTap;
  const _CardData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.badge,
    required this.accent,
    required this.priority,
    required this.onTap,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CARTE SERVICE — LOT 3 : `AppCard.elevated`/`.standard` (LOT 2) au lieu
// d'une carte blanche/dégradé pleine couleur codée en dur. Accent par icône
// uniquement (pas de fond saturé plein écran) — responsive, aucune taille
// fixe.
// ─────────────────────────────────────────────────────────────────────────────
class _ServiceCard extends StatelessWidget {
  final _CardData data;
  const _ServiceCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconSz = AppLayout.r(context, 44);
    final innerSz = AppLayout.iconMd(context);
    final titleColor = isDark
        ? AppColors.premiumTextPrimaryDark
        : AppColors.premiumTextPrimaryLight;
    final subtitleColor = isDark
        ? AppColors.premiumTextSecondaryDark
        : AppColors.premiumTextSecondaryLight;

    final content = Row(
      children: [
        // Icône
        Container(
          width: iconSz,
          height: iconSz,
          decoration: BoxDecoration(
            color: d.accent.withValues(alpha: isDark ? 0.22 : 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(d.icon, color: d.accent, size: innerSz),
        ),

        SizedBox(width: AppLayout.lg(context)),

        // Texte
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Badge
              Container(
                constraints: const BoxConstraints(minHeight: 24),
                margin: EdgeInsets.only(bottom: AppLayout.xs(context) + 1),
                padding: EdgeInsets.symmetric(
                  horizontal: AppLayout.sm(context),
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: d.accent.withValues(alpha: isDark ? 0.18 : 0.10),
                  borderRadius: AppRadius.pillR,
                  border: Border.all(
                    color: d.accent.withValues(alpha: isDark ? 0.34 : 0.22),
                  ),
                ),
                child: Text(
                  d.badge,
                  style: GoogleFonts.urbanist(
                    color: d.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              Text(
                d.title,
                style: AppTypography.titleMediumStyle(context,
                    color: titleColor, weight: FontWeight.w700),
              ),
              SizedBox(height: AppLayout.xs(context) / 2),
              Text(
                d.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.urbanist(
                  color: subtitleColor,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),

        // Flèche
        SizedBox(
          width: AppLayout.r(context, 44),
          height: AppLayout.r(context, 44),
          child: Center(
            child: Container(
              width: AppLayout.r(context, 32),
              height: AppLayout.r(context, 32),
              decoration: BoxDecoration(
                color: d.accent.withValues(alpha: isDark ? 0.18 : 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: d.accent.withValues(alpha: isDark ? 0.30 : 0.18),
                ),
              ),
              child: Icon(
                Icons.arrow_forward_rounded,
                color: d.accent,
                size: AppLayout.iconSm(context) - 1,
              ),
            ),
          ),
        ),
      ],
    );

    final cardPadding = EdgeInsets.symmetric(
      horizontal: AppLayout.lg(context) + 2,
      vertical: AppLayout.md(context) + 2,
    );

    final card = d.priority
        ? AppCard.elevated(onTap: d.onTap, padding: cardPadding, child: content)
        : AppCard.standard(
            onTap: d.onTap, padding: cardPadding, child: content);

    return Container(
      key:
          ValueKey('home-service-card-${d.priority ? 'elevated' : 'standard'}'),
      constraints: BoxConstraints(minHeight: AppLayout.r(context, 76)),
      decoration: BoxDecoration(
        borderRadius: AppRadius.premiumXlR,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.16 : 0.055),
            blurRadius: d.priority ? 15 : 11,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: card,
    );
  }
}
