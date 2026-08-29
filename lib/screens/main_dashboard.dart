import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n/app_text.dart';
import '../theme/app_theme.dart';
import '../marketplace/screens/mp_home_screen.dart';
import '../widgets/tap_effect.dart';
import 'client/client_map.dart';
import 'client/livraison_screen.dart';
import 'client/suivi_commande.dart';
import 'client/profil_client.dart';
import 'auth/client_auth_page.dart';

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

@visibleForTesting
bool isAuthenticatedClientSession({
  required bool hasUser,
  required bool isAnonymous,
}) =>
    hasUser && !isAnonymous;

class _MainDashboardState extends State<MainDashboard>
    with TickerProviderStateMixin {
  int _currentIndex = 0;

  // Pages créées à la demande — évite d'initialiser GPS+Firestore pour
  // des pages jamais visitées. Null = pas encore créée.
  final List<Widget?> _pages = List.filled(4, null);

  static Widget _buildPage(int index) => switch (index) {
        0 => const ClientMap(),
        1 => const MpHomeScreen(),
        2 => const SuiviCommandePage(),
        3 => const ProfilClient(),
        _ => const SizedBox.shrink(),
      };

  @override
  void initState() {
    super.initState();
    _pages[0] = const ClientMap(); // page d'accueil toujours prête
  }

  void _navigate(int index) {
    if (_currentIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pages[index] ??=
          _buildPage(index); // créée seulement à la première visite
      _currentIndex = index;
    });
  }

  void _openCommander() {
    HapticFeedback.mediumImpact();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => buildClientOrderScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText(AppLanguage.of(context).locale);

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (!isAuthenticatedClientSession(
          hasUser: user != null,
          isAnonymous: user?.isAnonymous ?? true,
        )) {
          return const ClientAuthPage();
        }

        return PopScope(
          canPop: _currentIndex == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            setState(() => _currentIndex = 0);
          },
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.dark,
            child: Scaffold(
              extendBody: true,
              body: IndexedStack(
                index: _currentIndex,
                children: List.generate(
                  4,
                  (i) => _pages[i] ?? const SizedBox.shrink(),
                ),
              ),
              bottomNavigationBar: _FloatingNav(
                currentIndex: _currentIndex,
                text: text,
                onTap: _navigate,
                onCommander: _openCommander,
              ),
            ),
          ),
        );
      },
    );
  }
}

@visibleForTesting
Widget buildClientOrderScreen() => const LivraisonScreen();

// ─────────────────────────────────────────────────────────────────────────────
// BOUTON FLOTTANT AZ IA — accès rapide à l'assistant conversationnel
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// NAVIGATION FLOTTANTE RESPONSIVE
// ─────────────────────────────────────────────────────────────────────────────
class _FloatingNav extends StatelessWidget {
  final int currentIndex;
  final AppText text;
  final ValueChanged<int> onTap;
  final VoidCallback onCommander;

  const _FloatingNav({
    required this.currentIndex,
    required this.text,
    required this.onTap,
    required this.onCommander,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = AppLayout.safeBottom(context);
    final navH = AppLayout.r(context, 72);
    final hPad = AppLayout.lg(context);
    final bPad = safeBottom + AppLayout.sm(context) + 4;

    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, bPad),
      child: Container(
        height: navH,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: AppRadius.xxlR,
          boxShadow: AppShadow.navFloat,
        ),
        child: Row(
          children: [
            _NavTab(
              icon: Icons.home_rounded,
              iconOff: Icons.home_outlined,
              label: text.t('home'),
              selected: currentIndex == 0,
              onTap: () => onTap(0),
            ),
            _NavTab(
              icon: Icons.storefront_rounded,
              iconOff: Icons.storefront_outlined,
              label: 'Djassa',
              selected: currentIndex == 1,
              onTap: () => onTap(1),
            ),
            _CommanderButton(onTap: onCommander),
            _NavTab(
              icon: Icons.receipt_long_rounded,
              iconOff: Icons.receipt_long_outlined,
              label: text.t('tracking'),
              selected: currentIndex == 2,
              onTap: () => onTap(2),
            ),
            _NavTab(
              icon: Icons.person_rounded,
              iconOff: Icons.person_outline_rounded,
              label: text.t('profile'),
              selected: currentIndex == 3,
              onTap: () => onTap(3),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB RESPONSIVE
// ─────────────────────────────────────────────────────────────────────────────
class _NavTab extends StatelessWidget {
  final IconData icon;
  final IconData iconOff;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavTab({
    required this.icon,
    required this.iconOff,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const kPrimary = AppColors.primary;
    final iconSize = AppLayout.iconMd(context);
    final labelSize = AppTypography.labelSmall(context);

    return Expanded(
      // Master Prompt 124 (Partie 17) — aucun onglet de navigation n'était
      // annoncé aux lecteurs d'écran (zéro Semantics() dans tout le projet
      // avant cette passe) ; un seul Semantics combiné plutôt que de laisser
      // l'icône et le texte être annoncés séparément (excludeSemantics).
      child: Semantics(
        label: label,
        selected: selected,
        button: true,
        onTap: onTap,
        excludeSemantics: true,
        child: TapEffect(
          onTap: onTap,
          scaleDown: 0.92,
          haptic: HapticType.selection,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Indicateur pill
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(
                  horizontal:
                      selected ? AppLayout.md(context) : AppLayout.sm(context),
                  vertical: AppLayout.xs(context),
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? kPrimary.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: AppRadius.pillR,
                ),
                // Master Prompt 124 — l'onglet actif grandit légèrement plutôt
                // que de ne changer que sa couleur, pour un feedback plus vivant.
                child: AnimatedScale(
                  scale: selected ? 1.12 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    selected ? icon : iconOff,
                    color: selected ? kPrimary : AppColors.textLight,
                    size: iconSize,
                  ),
                ),
              ),
              SizedBox(height: AppLayout.xs(context) / 2),
              // Label
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: GoogleFonts.urbanist(
                  fontSize: labelSize,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? kPrimary : AppColors.textLight,
                ),
                child:
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOUTON COMMANDER RESPONSIVE
// ─────────────────────────────────────────────────────────────────────────────
class _CommanderButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CommanderButton({required this.onTap});

  @override
  State<_CommanderButton> createState() => _CommanderButtonState();
}

class _CommanderButtonState extends State<_CommanderButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 140));
    _scale = Tween<double>(begin: 1.0, end: 0.88)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final btnSize = AppLayout.r(context, 52);
    final iconSize = AppLayout.iconLg(context);
    final hPad = AppLayout.sm(context) - 2;

    // Master Prompt 124 (Partie 17) — bouton icône seule ("+"), sans texte ni
    // tooltip : rien à annoncer pour un lecteur d'écran sans ce Semantics.
    return Semantics(
      label: 'Commander',
      button: true,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) {
          _ctrl.forward();
          HapticFeedback.mediumImpact();
        },
        onTapUp: (_) {
          _ctrl.reverse();
          widget.onTap();
        },
        onTapCancel: () => _ctrl.reverse(),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: ScaleTransition(
            scale: _scale,
            child: Container(
              width: btnSize,
              height: btnSize,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primaryLight, AppColors.primaryDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: AppShadow.colored(AppColors.primary, opacity: 0.45),
              ),
              child: Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: iconSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
