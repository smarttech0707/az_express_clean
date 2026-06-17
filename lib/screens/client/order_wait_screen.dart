import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/order_model.dart';
import '../../services/notification_service.dart';
import 'order_tracking_map.dart';

/// Écran affiché immédiatement après la création d'une commande.
/// Phase 1 : animation radar "Recherche d'un livreur…"
/// Phase 2 : dès qu'un livreur accepte, affiche "Trouvé !" et ouvre la carte.
class OrderWaitScreen extends StatefulWidget {
  final OrderModel order;
  const OrderWaitScreen({super.key, required this.order});

  @override
  State<OrderWaitScreen> createState() => _OrderWaitScreenState();
}

class _OrderWaitScreenState extends State<OrderWaitScreen>
    with TickerProviderStateMixin {

  // Animation radar (recherche)
  late final AnimationController _radarCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  // Animation coche (livreur trouvé)
  late final AnimationController _checkCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final Animation<double> _checkScale = CurvedAnimation(
    parent: _checkCtrl,
    curve: Curves.elasticOut,
  );

  StreamSubscription? _orderSub;
  OrderModel?         _order;
  bool                _driverFound = false;
  bool                _navigating  = false;

  // 0 = recherche initiale · 1 = rayon élargi · 2 = toute la zone
  int   _searchPhase = 0;
  Timer? _phase1Timer;
  Timer? _phase2Timer;

  static const _green     = Color(0xFF2E7D32);
  static const _lightGreen = Color(0xFF4CAF50);
  static const _orange    = Color(0xFFFF7A1A);

  @override
  void initState() {
    super.initState();
    _order = widget.order;
    _listenOrder();
    _startSearchPhaseTimers();
  }

  void _startSearchPhaseTimers() {
    _phase1Timer = Timer(const Duration(seconds: 30), () {
      if (!mounted || _driverFound) return;
      setState(() => _searchPhase = 1);
      NotificationService.showLocalBanner(
        title: '📡 Recherche élargie',
        body: 'Nous contactons plus de livreurs à proximité.',
        type: 'order_update',
      );
    });
    _phase2Timer = Timer(const Duration(seconds: 60), () {
      if (!mounted || _driverFound) return;
      setState(() => _searchPhase = 2);
      NotificationService.showLocalBanner(
        title: '📡 Zone complète',
        body: 'Nous recherchons maintenant dans toute la zone d\'Abengourou.',
        type: 'order_update',
      );
    });
  }

  @override
  void dispose() {
    _orderSub?.cancel();
    _phase1Timer?.cancel();
    _phase2Timer?.cancel();
    _radarCtrl.dispose();
    _checkCtrl.dispose();
    super.dispose();
  }

  // ── Écoute en temps réel l'ordre Firestore ───────────────────────────────

  void _listenOrder() {
    _orderSub = FirebaseFirestore.instance
        .collection('orders')
        .doc(widget.order.id)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final data = snap.data();
      if (data == null) return;
      final updated = OrderModel.fromMap(snap.id, data);
      setState(() => _order = updated);

      // Livreur assigné / en route
      if (!_driverFound &&
          updated.driverId != null &&
          (updated.status == 'assigned' ||
           updated.status == 'accepted' ||
           updated.status == 'picked_up')) {
        _onDriverFound(updated);
      }

      // Annulée par le système
      if (updated.status == 'cancelled' && !_driverFound && mounted) {
        _showCancelled();
      }
    });
  }

  void _onDriverFound(OrderModel updated) {
    setState(() => _driverFound = true);
    _radarCtrl.stop();
    _checkCtrl.forward();

    Future.delayed(const Duration(milliseconds: 2200), () {
      if (!mounted || _navigating) return;
      _navigating = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OrderTrackingMap(order: updated),
        ),
      );
    });
  }

  void _showCancelled() {
    if (!mounted) return;
    _phase1Timer?.cancel();
    _phase2Timer?.cancel();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.white,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.sentiment_dissatisfied_rounded,
                  color: Colors.orange.shade700, size: 34),
            ),
            const SizedBox(height: 14),
            Text(
              'Aucun livreur disponible',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: Text(
          'Nous n\'avons pas trouvé de livreur disponible dans votre zone pour le moment.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
              fontSize: 13.5, color: Colors.grey.shade600, height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFFF6B00)),
              foregroundColor: const Color(0xFFFF6B00),
              minimumSize: const Size(120, 44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(context); // ferme dialog
              Navigator.pop(context); // retourne au dashboard
            },
            child: Text('Annuler', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B00),
              foregroundColor: Colors.white,
              minimumSize: const Size(120, 44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            onPressed: () async {
              Navigator.pop(context); // ferme dialog
              // Relance la recherche : recrée un document avec le même contenu
              try {
                await FirebaseFirestore.instance
                    .collection('orders')
                    .doc(widget.order.id)
                    .update({'status': 'pending', 'driverId': null});
                if (mounted) {
                  setState(() {
                    _searchPhase = 0;
                    _driverFound = false;
                  });
                  _radarCtrl.repeat();
                  _startSearchPhaseTimers();
                }
              } catch (_) {
                if (mounted) Navigator.pop(context);
              }
            },
            child: Text('Réessayer', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelOrder() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Annuler la commande ?',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Text(
          'La recherche sera interrompue et votre commande supprimée.',
          style: GoogleFonts.inter(
              fontSize: 13, color: Colors.grey.shade600),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Garder',
                style: GoogleFonts.inter(color: Colors.grey.shade600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Annuler la commande',
                style: GoogleFonts.inter(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(widget.order.id)
          .update({'status': 'cancelled'});
      if (mounted) Navigator.pop(context);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final o = _order ?? widget.order;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return PopScope(
      canPop: !_driverFound,
      child: Scaffold(
        backgroundColor: const Color(0xFF1B4332),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, bottomPad + 16),
            child: Column(children: [

              // ── En-tête ─────────────────────────────────────────────────
              Row(children: [
                if (!_driverFound)
                  GestureDetector(
                    onTap: _cancelOrder,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded,
                          color: Colors.white70, size: 20),
                    ),
                  )
                else
                  const SizedBox(width: 36),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: _driverFound
                            ? _lightGreen
                            : Colors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _driverFound ? 'Livreur assigné' : 'En attente',
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70),
                    ),
                  ]),
                ),
              ]),

              const SizedBox(height: 40),

              // ── Animation centrale ───────────────────────────────────────
              SizedBox(
                height: 180,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _driverFound
                      ? _buildCheckAnim()
                      : _buildRadarAnim(),
                ),
              ),

              const SizedBox(height: 36),

              // ── Texte statut ─────────────────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _driverFound
                    ? _buildFoundText()
                    : _buildSearchText(),
              ),

              const SizedBox(height: 28),

              // ── Carte commande ───────────────────────────────────────────
              _buildOrderCard(o),

              const Spacer(),

              // ── Bouton annulation ────────────────────────────────────────
              if (!_driverFound)
                GestureDetector(
                  onTap: _cancelOrder,
                  child: Text(
                    'Annuler la commande',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.red.shade300,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.red.shade300,
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Animation radar ──────────────────────────────────────────────────────

  Widget _buildRadarAnim() {
    return AnimatedBuilder(
      key: const ValueKey('radar'),
      animation: _radarCtrl,
      builder: (_, __) {
        final t = _radarCtrl.value;
        return Stack(alignment: Alignment.center, children: [
          _ring(t,          offset: 0.00, maxR: 160),
          _ring(t,          offset: 0.35, maxR: 160),
          _ring(t,          offset: 0.70, maxR: 160),
          // Icône centrale
          Container(
            width: 80, height: 80,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _green,
            ),
            child: const Icon(Icons.delivery_dining_rounded,
                color: Colors.white, size: 40),
          ),
        ]);
      },
    );
  }

  Widget _ring(double t, {required double offset, required double maxR}) {
    final progress = ((t - offset) / (1 - offset)).clamp(0.0, 1.0);
    if (progress <= 0) return const SizedBox.shrink();
    final opacity  = (1 - progress) * 0.45;
    final diameter = 80.0 + progress * (maxR - 80);
    return Opacity(
      opacity: opacity,
      child: Container(
        width: diameter, height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _lightGreen, width: 1.5),
        ),
      ),
    );
  }

  // ── Animation coche ──────────────────────────────────────────────────────

  Widget _buildCheckAnim() {
    return ScaleTransition(
      key: const ValueKey('check'),
      scale: _checkScale,
      child: Container(
        width: 100, height: 100,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: _lightGreen,
        ),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 56),
      ),
    );
  }

  // ── Textes ───────────────────────────────────────────────────────────────

  Widget _buildSearchText() {
    final titles = [
      'Recherche d\'un livreur…',
      '📡 Élargissement de la recherche…',
      '📡 Recherche dans toute la zone…',
    ];
    final subtitles = [
      'Votre commande a bien été envoyée.\nUn livreur va être assigné dans quelques instants.',
      'Nous contactons tous les livreurs\ndisponibles à proximité.',
      'Nous recherchons maintenant dans\ntoute la zone d\'Abengourou.',
    ];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: Column(
        key: ValueKey(_searchPhase),
        children: [
          Text(titles[_searchPhase],
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
          const SizedBox(height: 8),
          Text(
            subtitles[_searchPhase],
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
                fontSize: 13,
                color: Colors.white60,
                height: 1.55),
          ),
        ],
      ),
    );
  }

  Widget _buildFoundText() {
    return Column(
      key: const ValueKey('found_txt'),
      children: [
        Text('Livreur trouvé !',
            style: GoogleFonts.inter(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
        const SizedBox(height: 8),
        Text('Ouverture du suivi en direct…',
            style: GoogleFonts.inter(
                fontSize: 13, color: Colors.green.shade300)),
      ],
    );
  }

  // ── Carte récap commande ─────────────────────────────────────────────────

  Widget _buildOrderCard(OrderModel o) {
    final isExpress = o.deliveryMode == 'express';
    final modeColor = isExpress ? _orange : _lightGreen;
    final modeLabel = isExpress ? 'EXPRESS' : 'STANDARD';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Articles
          Row(children: [
            const Icon(Icons.shopping_basket_rounded,
                color: Colors.white54, size: 15),
            const SizedBox(width: 8),
            Expanded(child: Text(
              o.description.split('\n').first,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            )),
          ]),

          const SizedBox(height: 10),

          // Adresse
          Row(children: [
            const Icon(Icons.place_rounded,
                color: Colors.white38, size: 14),
            const SizedBox(width: 6),
            Expanded(child: Text(
              o.deliveryAddress ?? '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                  fontSize: 12, color: Colors.white54),
            )),
          ]),

          const SizedBox(height: 12),

          Divider(height: 1, color: Colors.white.withValues(alpha: 0.12)),

          const SizedBox(height: 12),

          // Mode + montant
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: modeColor.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: modeColor.withValues(alpha: 0.45)),
              ),
              child: Text(modeLabel,
                  style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: modeColor)),
            ),
            const Spacer(),
            Text(
              '${o.budget} FCFA',
              style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.white),
            ),
          ]),
        ],
      ),
    );
  }
}
