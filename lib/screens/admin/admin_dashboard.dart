import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_kit.dart';
import '../../widgets/logout_confirm_dialog.dart';
import '../../widgets/single_photo_editor.dart';
import '../home/home_screen.dart';
import 'admin_service_requests_page.dart';
import 'driver_requests_page.dart';
import 'admin_login.dart';
import 'admin_menu.dart';
import 'admin_mfa_security.dart';

class AdminDashboard extends StatefulWidget {
  final Map<String, dynamic> adminData;
  final bool twoFactorBypassed;
  const AdminDashboard({
    super.key,
    required this.adminData,
    this.twoFactorBypassed = false,
  });

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  late Map<String, dynamic> _adminData = Map.of(widget.adminData);
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _adminSubscription;
  bool _closingForInvalidSession = false;

  bool get _isSuper => _adminData['role'] == 'super';
  List<String> get _perms => List<String>.from(_adminData['permissions'] ?? []);
  late String? _photoUrl = _adminData['photoUrl'] as String?;
  OverlayEntry? _twoFactorWarningOverlay;

  @override
  void initState() {
    super.initState();
    final expectedUid = widget.adminData['uid'] as String?;
    if (expectedUid == null || !validateAdminRecord(_adminData).allowed) {
      _closeInvalidSession();
    } else {
      _authSubscription =
          FirebaseAuth.instance.authStateChanges().listen((user) {
        if (!isAdminSessionValid(
          currentUid: user?.uid,
          isAnonymous: user?.isAnonymous ?? true,
          expectedUid: expectedUid,
          adminData: _adminData,
        )) {
          _closeInvalidSession();
        }
      });
      _adminSubscription = FirebaseFirestore.instance
          .collection('admins')
          .doc(expectedUid)
          .snapshots()
          .listen((snapshot) {
        final data = snapshot.data();
        if (!snapshot.exists || !validateAdminRecord(data).allowed) {
          _closeInvalidSession();
          return;
        }
        if (mounted) {
          setState(() => _adminData = {'uid': expectedUid, ...data!});
        }
      }, onError: (_) => _closeInvalidSession());
    }
    if (widget.twoFactorBypassed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _twoFactorWarningOverlay != null) return;
        _twoFactorWarningOverlay = OverlayEntry(
          builder: (_) => const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(child: AdminTwoFactorBypassBanner()),
          ),
        );
        Overlay.of(context, rootOverlay: true)
            .insert(_twoFactorWarningOverlay!);
      });
    }
    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted || _closingForInvalidSession) return;
      if (type == 'admin_new_driver') {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const DriverRequestsPage()));
      } else if (type == 'admin_new_service_provider') {
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const AdminServiceRequestsPage()));
      }
    }, acceptedTypes: const {
      'admin_new_driver',
      'admin_new_service_provider',
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _adminSubscription?.cancel();
    _twoFactorWarningOverlay?.remove();
    _twoFactorWarningOverlay = null;
    NotificationService.unregisterTapHandler();
    super.dispose();
  }

  void _closeInvalidSession() {
    if (_closingForInvalidSession) return;
    _closingForInvalidSession = true;
    NotificationService.unregisterTapHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AdminLogin()),
        (_) => false,
      );
    });
  }

  // Master Prompt 135 — bouton Déconnexion manquant sur ce tableau de bord
  // (seul rôle sans aucun point de sortie, contrairement à tous les autres).
  // Même pattern déjà établi ailleurs (confirmation → logAuthEvent → signOut
  // → signInAnonymously → retour HomeScreen) — ne touche à aucune logique
  // métier, ne modifie aucune vérification de rôle déjà faite avant l'accès
  // à cet écran (admin_login.dart).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'admin');
    await FirebaseAuth.instance.signOut();
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_closingForInvalidSession) return const SizedBox.shrink();
    final adminName = (_adminData['name'] as String?) ?? '';
    final isSuper = _isSuper;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // ── APP BAR PREMIUM ─────────────────────────────
          SliverAppBar(
            expandedHeight: 170,
            floating: false,
            pinned: true,
            backgroundColor: AppColors.primary,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFFE65100),
                      AppColors.primary,
                      Color(0xFFFF8C42)
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    stops: [0.0, 0.5, 1.0],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            // Avatar — photo de profil admin (Master Prompt
                            // "photos manquantes"), repli sur l'icône rôle
                            // si aucune photo n'est encore définie.
                            SinglePhotoEditor(
                              photoUrl: _photoUrl,
                              storagePath:
                                  'admin_photos/${_adminData['uid']}/profile.jpg',
                              size: 48,
                              placeholderIcon: isSuper
                                  ? Icons.admin_panel_settings_rounded
                                  : Icons.manage_accounts_rounded,
                              onUploaded: (url) async {
                                await FirebaseFirestore.instance
                                    .collection('admins')
                                    .doc(_adminData['uid'])
                                    .update({'photoUrl': url});
                                if (mounted) setState(() => _photoUrl = url);
                              },
                              onDeleted: () async {
                                await FirebaseFirestore.instance
                                    .collection('admins')
                                    .doc(_adminData['uid'])
                                    .update({'photoUrl': FieldValue.delete()});
                                if (mounted) setState(() => _photoUrl = null);
                              },
                            ),
                            const SizedBox(width: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isSuper
                                      ? 'Administration'
                                      : (adminName.isNotEmpty
                                          ? adminName
                                          : 'Sous-Admin'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    borderRadius: AppRadius.pillR,
                                  ),
                                  child: Text(
                                    isSuper
                                        ? 'AZ Express — Super Admin'
                                        : 'AZ Express — Accès limité',
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.92),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(
              isSuper ? 'Admin AZ Express' : 'Tableau de bord',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
            centerTitle: true,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Déconnexion',
                onPressed: _logout,
              ),
            ],
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isSuper) ...[
                    _StatsRow(),
                    const SizedBox(height: 24),
                  ],
                  Row(
                    children: [
                      const Text(
                        'Gestion',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: const BoxDecoration(
                          color: AppColors.primary10,
                          borderRadius: AppRadius.pillR,
                        ),
                        child: const Text(
                          'AZ Express',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  AdminMenu(isSuper: isSuper, permissions: _perms),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
class AdminTwoFactorBypassBanner extends StatelessWidget {
  const AdminTwoFactorBypassBanner({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          key: const Key('admin-2fa-debug-bypass-banner'),
          width: double.infinity,
          color: const Color(0xFFB71C1C),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  '2FA DÉSACTIVÉE — MODE DEV',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

// ── STATS ROW ────────────────────────────────────────────────────────────────

class _StatsRow extends StatefulWidget {
  @override
  State<_StatsRow> createState() => _StatsRowState();
}

class _StatsRowState extends State<_StatsRow> {
  int _totalOrders = 0;
  int _delivered = 0;
  int _totalDrivers = 0;
  int _online = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final db = FirebaseFirestore.instance;
      final results = await Future.wait([
        db.collection('orders').count().get(),
        db
            .collection('orders')
            .where('status', isEqualTo: 'delivered')
            .count()
            .get(),
        db.collection('livreurs').count().get(),
        db
            .collection('livreurs')
            .where('isOnline', isEqualTo: true)
            .count()
            .get(),
      ]);
      if (!mounted) return;
      setState(() {
        _totalOrders = results[0].count ?? 0;
        _delivered = results[1].count ?? 0;
        _totalDrivers = results[2].count ?? 0;
        _online = results[3].count ?? 0;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Row(
        children: [
          Expanded(
              child: AzShimmer(
                  width: double.infinity, height: 80, radius: AppRadius.xl)),
          SizedBox(width: 10),
          Expanded(
              child: AzShimmer(
                  width: double.infinity, height: 80, radius: AppRadius.xl)),
          SizedBox(width: 10),
          Expanded(
              child: AzShimmer(
                  width: double.infinity, height: 80, radius: AppRadius.xl)),
        ],
      );
    }
    return Row(
      children: [
        _StatChip(
          value: '$_totalOrders',
          label: 'Commandes',
          icon: Icons.shopping_bag_rounded,
          color: AppColors.primary,
          onTap: _load,
        ),
        const SizedBox(width: 10),
        _StatChip(
          value: '$_online/$_totalDrivers',
          label: 'En ligne',
          icon: Icons.delivery_dining_rounded,
          color: const Color(0xFF1565C0),
          onTap: _load,
        ),
        const SizedBox(width: 10),
        _StatChip(
          value: '$_delivered',
          label: 'Livrées',
          icon: Icons.check_circle_rounded,
          color: const Color(0xFF1B5E20),
          onTap: _load,
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _StatChip({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ScaleTap(
        onTap: onTap,
        child: PremiumCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: AppRadius.mdR,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── MENU CARD ──────────────────────────────────────────────────────────────
