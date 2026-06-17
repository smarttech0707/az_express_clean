import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

// ── Handler background — doit être top-level (hors classe) ───────────
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase est déjà initialisé avant ce callback
}

// ── Service Notifications (Singleton) ────────────────────────────────
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  // NavigatorKey partagé — fourni par main.dart
  static GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  // Badge non-lu — observé par les widgets via ValueListenableBuilder
  static final ValueNotifier<int> unreadCount = ValueNotifier(0);

  // Callback enregistré par le dashboard actif (driver ou client)
  // Arguments : type, orderId, status
  static void Function(String type, String? orderId, String? status)?
      _tapCallback;

  static void registerTapHandler(
      void Function(String type, String? orderId, String? status) cb) {
    _tapCallback = cb;
  }

  static void unregisterTapHandler() => _tapCallback = null;

  // Utilisateur connecté (pour mise à jour du token lors du refresh)
  String? _userId;
  String? _userCollection;

  // ── Initialisation principale ─────────────────────────────────────
  Future<void> init() async {
    // Enregistrer le handler background
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Demander la permission
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    // iOS : afficher la notification même quand l'app est au premier plan
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Foreground : afficher notre bannière personnalisée
    FirebaseMessaging.onMessage.listen(_handleForeground);

    // Tap sur notification (app en arrière-plan)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

    // App lancée depuis une notification (état terminé)
    final initial = await _fcm.getInitialMessage();
    if (initial != null) _handleTap(initial);

    // Rafraîchissement automatique du token
    _fcm.onTokenRefresh.listen(_onTokenRefresh);
  }

  // ── Sauvegarder le token d'un utilisateur dans Firestore ──────────
  Future<void> saveToken(String userId, String collection) async {
    try {
      _userId = userId;
      _userCollection = collection;
      final token = await _fcm.getToken();
      if (token == null) return;
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(userId)
          .set({'fcmToken': token}, SetOptions(merge: true));
      // Synchroniser le badge non-lu au démarrage (clients uniquement)
      if (collection == 'clients') _syncUnreadCount(userId);
    } catch (_) {}
  }

  // ── Synchronise le badge non-lu depuis Firestore ──────────────────
  Future<void> _syncUnreadCount(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('clients').doc(uid)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .count()
          .get();
      unreadCount.value = snap.count ?? 0;
    } catch (_) {}
  }

  // ── Sauvegarder la notification dans l'historique Firestore ───────
  Future<void> _saveNotification(RemoteMessage message) async {
    final uid = _userId;
    final col = _userCollection;
    if (uid == null || col != 'clients') return;
    final n = message.notification;
    if (n == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('clients').doc(uid)
          .collection('notifications').add({
        'title':     n.title ?? '',
        'body':      n.body ?? '',
        'type':      message.data['type'] ?? '',
        'orderId':   message.data['orderId'],
        'status':    message.data['status'],
        'isRead':    false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      unreadCount.value++;
    } catch (_) {}
  }

  // ── Marquer toutes les notifications comme lues ───────────────────
  static Future<void> markAllRead(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('clients').doc(uid)
          .collection('notifications')
          .where('isRead', isEqualTo: false)
          .get();
      if (snap.docs.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
      await batch.commit();
      unreadCount.value = 0;
    } catch (_) {}
  }

  // ── Supprimer une notification ────────────────────────────────────
  static Future<void> deleteNotification(String uid, String notifId) async {
    try {
      await FirebaseFirestore.instance
          .collection('clients').doc(uid)
          .collection('notifications').doc(notifId).delete();
    } catch (_) {}
  }

  // ── Stream de l'historique (100 dernières) ────────────────────────
  static Stream<QuerySnapshot<Map<String, dynamic>>> streamNotifications(
      String uid) {
    return FirebaseFirestore.instance
        .collection('clients').doc(uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
  }

  // ── Token rafraîchi → mettre à jour Firestore ─────────────────────
  void _onTokenRefresh(String token) {
    if (_userId == null || _userCollection == null) return;
    FirebaseFirestore.instance
        .collection(_userCollection!)
        .doc(_userId!)
        .set({'fcmToken': token}, SetOptions(merge: true))
        .catchError((e) {
      debugPrint('[NotificationService] Erreur refresh token FCM : $e');
    });
  }

  // ── Message reçu en foreground → bannière in-app + historique ─────
  void _handleForeground(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    _saveNotification(message);
    _showBanner(
      title: n.title ?? '',
      body: n.body ?? '',
      data: message.data,
      icon: _iconForType(message.data['type']),
      color: _colorForType(message.data['type']),
    );
  }

  // ── Tap sur notification → navigation ─────────────────────────────
  void _handleTap(RemoteMessage message) {
    final type    = message.data['type']    as String?;
    final orderId = message.data['orderId'] as String?;
    final status  = message.data['status']  as String?;
    _tapCallback?.call(type ?? '', orderId, status);
  }

  // ── Bannière locale (sans FCM) — ETA, recherche élargie, etc. ────
  static void showLocalBanner({
    required String title,
    required String body,
    String type = '',
  }) {
    _instance._showBanner(
      title: title,
      body: body,
      data: {'type': type},
      icon: _instance._iconForType(type),
      color: _instance._colorForType(type),
    );
  }

  // ── Afficher la bannière en overlay ───────────────────────────────
  void _showBanner({
    required String title,
    required String body,
    required Map<String, dynamic> data,
    required IconData icon,
    required Color color,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _NotificationBanner(
        title: title,
        body: body,
        icon: icon,
        color: color,
        onDismiss: () {
          if (entry.mounted) entry.remove();
        },
        onTap: () {
          if (entry.mounted) entry.remove();
          _handleTap(RemoteMessage(data: data));
        },
      ),
    );

    overlay.insert(entry);

    // Auto-dismiss après 5 secondes
    Future.delayed(const Duration(seconds: 5), () {
      if (entry.mounted) entry.remove();
    });
  }

  // ── Icône selon le type de notification ───────────────────────────
  IconData _iconForType(String? type) {
    switch (type) {
      case 'new_order':
      case 'new_seller_order':
      case 'new_pharmacie_order':
      case 'new_boulangerie_order':
        return Icons.delivery_dining_rounded;
      // Client — confirmation commande créée
      case 'order_confirmed':
        return Icons.check_circle_rounded;
      // Client — livreur/partenaire trouvé
      case 'driver_found':
        return Icons.two_wheeler_rounded;
      // Client/livreur — mise à jour statut en cours
      case 'order_update':
        return Icons.local_shipping_rounded;
      // Livreur — mission terminée
      case 'mission_end':
        return Icons.task_alt_rounded;
      case 'order_cancelled':
        return Icons.cancel_rounded;
      case 'low_balance':
        return Icons.account_balance_wallet_rounded;
      case 'admin_new_driver':
        return Icons.person_add_rounded;
      case 'admin_new_service_provider':
        return Icons.store_rounded;
      case 'message':
        return Icons.chat_bubble_rounded;
      case 'recharge':
        return Icons.account_balance_wallet_rounded;
      // E-Kbine — nouvelle demande agent
      case 'ek_new_order':
        return Icons.account_balance_rounded;
      // E-Kbine — suivi client
      case 'ek_update':
        return Icons.update_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  // ── Couleur selon le type ─────────────────────────────────────────
  Color _colorForType(String? type) {
    switch (type) {
      case 'new_order':
      case 'new_seller_order':
      case 'new_pharmacie_order':
      case 'new_boulangerie_order':
        return const Color(0xFF2E7D32);
      case 'order_confirmed':
        return const Color(0xFF2E7D32);
      case 'driver_found':
        return const Color(0xFF1B5E20);
      case 'order_update':
        return const Color(0xFF1565C0);
      case 'mission_end':
        return const Color(0xFF00695C);
      case 'order_cancelled':
        return Colors.red;
      case 'low_balance':
        return Colors.red;
      case 'admin_new_driver':
      case 'admin_new_service_provider':
        return const Color(0xFF6A1B9A);
      case 'recharge':
        return const Color(0xFF00695C);
      case 'ek_new_order':
        return const Color(0xFF4A148C);
      case 'ek_update':
        return const Color(0xFF1565C0);
      default:
        return const Color(0xFFFF6D00);
    }
  }
}

// ── Widget bannière in-app ────────────────────────────────────────────

class _NotificationBanner extends StatefulWidget {
  final String title;
  final String body;
  final IconData icon;
  final Color color;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  const _NotificationBanner({
    required this.title,
    required this.body,
    required this.icon,
    required this.color,
    required this.onDismiss,
    required this.onTap,
  });

  @override
  State<_NotificationBanner> createState() => _NotificationBannerState();
}

class _NotificationBannerState extends State<_NotificationBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topPad + 12,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                  border: Border.all(
                    color: widget.color.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: widget.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(widget.icon, color: widget.color, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.body,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12.5,
                              height: 1.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: widget.onDismiss,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            size: 14, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
