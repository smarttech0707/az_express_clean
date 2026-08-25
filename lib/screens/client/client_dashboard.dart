import 'package:flutter/material.dart';

import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_kit.dart';
import 'client_map.dart';
import 'client_wallet_page.dart';
import 'notification_center.dart';
import 'suivi_commande.dart';
import 'profil_client.dart';
import 'livraison_screen.dart';

class ClientDashboard extends StatefulWidget {
  const ClientDashboard({super.key});

  @override
  State<ClientDashboard> createState() => _ClientDashboardState();
}

class _ClientDashboardState extends State<ClientDashboard>
    with TickerProviderStateMixin {
  int _currentIndex = 0;

  static const List<Widget> _pages = [
    ClientMap(),
    ClientWalletPage(),
    SuiviCommandePage(),
    ProfilClient(),
  ];

  late AnimationController _fabCtrl;
  late Animation<double> _fabScale;

  @override
  void initState() {
    super.initState();
    _fabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _fabScale = Tween<double>(begin: 1.0, end: 0.90)
        .animate(CurvedAnimation(parent: _fabCtrl, curve: Curves.easeOut));

    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted) return;
      if ([
        'order_update',
        'driver_found',
        'order_confirmed',
        'order_cancelled',
        'mission_end'
      ].contains(type)) {
        setState(() => _currentIndex = 2);
      }
    });
  }

  @override
  void dispose() {
    NotificationService.unregisterTapHandler();
    _fabCtrl.dispose();
    super.dispose();
  }

  void _openNewOrder() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LivraisonScreen()),
    );
  }

  void _openNotificationCenter() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const NotificationCenterScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: IndexedStack(
              index: _currentIndex,
              children: _pages,
            ),
          ),
          // ── Cloche notifications (badge non-lu) ─────────────────────────
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 10, right: 14),
                child: ValueListenableBuilder<int>(
                  valueListenable: NotificationService.unreadCount,
                  builder: (_, count, __) => _NotificationBell(
                    count: count,
                    onTap: _openNotificationCenter,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _buildFAB(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _buildBottomNav(context),
    );
  }

  Widget _buildFAB() {
    return Listener(
      onPointerDown: (_) => _fabCtrl.forward(),
      onPointerUp: (_) => _fabCtrl.reverse(),
      onPointerCancel: (_) => _fabCtrl.reverse(),
      child: GestureDetector(
        onTap: _openNewOrder,
        child: AnimatedBuilder(
          animation: _fabScale,
          builder: (_, child) =>
              Transform.scale(scale: _fabScale.value, child: child),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFFF8C42), AppColors.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.45),
                  blurRadius: 16,
                  offset: const Offset(0, 5),
                  spreadRadius: 0,
                ),
              ],
            ),
            child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 24,
            offset: Offset(0, -4),
          ),
          BoxShadow(
            color: Color(0x07000000),
            blurRadius: 6,
            offset: Offset(0, -1),
          ),
        ],
      ),
      child: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 10,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 72,
          child: Row(
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: 'Accueil',
                index: 0,
                current: _currentIndex,
                onTap: (i) => setState(() => _currentIndex = i),
              ),
              _NavItem(
                icon: Icons.account_balance_wallet_outlined,
                activeIcon: Icons.account_balance_wallet_rounded,
                label: 'Wallet',
                index: 1,
                current: _currentIndex,
                onTap: (i) => setState(() => _currentIndex = i),
              ),
              const SizedBox(width: 72),
              _NavItem(
                icon: Icons.location_on_outlined,
                activeIcon: Icons.location_on_rounded,
                label: 'Suivi',
                index: 2,
                current: _currentIndex,
                onTap: (i) => setState(() => _currentIndex = i),
              ),
              _NavItem(
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                label: 'Profil',
                index: 3,
                current: _currentIndex,
                onTap: (i) => setState(() => _currentIndex = i),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Cloche notifications avec badge ──────────────────────────────────────────
class _NotificationBell extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _NotificationBell({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.notifications_rounded,
                color: Colors.white, size: 22),
            if (count > 0)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF3B30),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      count > 9 ? '9+' : '$count',
                      style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Premium NavItem with animated pill indicator ─────────────────────────────
class _NavItem extends StatelessWidget {
  final IconData icon, activeIcon;
  final String label;
  final int index, current;
  final void Function(int) onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.index,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selected = index == current;
    const primary = AppColors.primary;

    return Expanded(
      child: ScaleTap(
        onTap: () => onTap(index),
        scaleDown: 0.88,
        haptic: true,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Pill indicator around icon
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                horizontal: selected ? 18 : 10,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: AppRadius.pillR,
              ),
              child: Icon(
                selected ? activeIcon : icon,
                color: selected ? primary : AppColors.textLight,
                size: 24,
              ),
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? primary : AppColors.textLight,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
