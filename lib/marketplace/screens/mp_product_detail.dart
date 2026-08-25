import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/mp_product.dart';
import '../mp_constants.dart';
import '../providers/mp_favorites_provider.dart';
import '../services/mp_service.dart';
import 'mp_chat_page.dart';

class MpProductDetail extends StatefulWidget {
  final MpProduct product;
  const MpProductDetail({super.key, required this.product});

  @override
  State<MpProductDetail> createState() => _MpProductDetailState();
}

class _MpProductDetailState extends State<MpProductDetail> {
  int _imgIndex = 0;
  late MpProduct _p;

  @override
  void initState() {
    super.initState();
    _p = widget.product;
    MpService.incrementViews(_p.id);
    context.read<MpFavoritesProvider>().load();
  }

  @override
  Widget build(BuildContext context) {
    final hasImages = _p.images.isNotEmpty;

    return Scaffold(
      backgroundColor: kMpBg,
      body: CustomScrollView(
        slivers: [
          // ── Gallery ─────────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: Colors.white,
            foregroundColor: kMpText,
            elevation: 0,
            actions: [
              Consumer<MpFavoritesProvider>(builder: (_, fav, __) {
                final isFav = fav.isFav(_p.id);
                return IconButton(
                  onPressed: () => fav.toggle(_p.id),
                  icon: Icon(
                    isFav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: isFav ? Colors.red : kMpMuted,
                  ),
                );
              }),
              IconButton(
                onPressed: _showReport,
                icon: const Icon(Icons.flag_outlined, color: kMpMuted),
                tooltip: 'Signaler',
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                children: [
                  if (hasImages)
                    PageView.builder(
                      itemCount: _p.images.length,
                      onPageChanged: (i) => setState(() => _imgIndex = i),
                      itemBuilder: (_, i) => Image.network(
                        _p.images[i],
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _imgPlaceholder(),
                        loadingBuilder: (_, child, prog) =>
                            prog == null ? child : _imgPlaceholder(),
                      ),
                    )
                  else
                    _imgPlaceholder(),
                  // Dots
                  if (_p.images.length > 1)
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          _p.images.length,
                          (i) => AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: _imgIndex == i ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: _imgIndex == i
                                  ? kMpOrange
                                  : Colors.white.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Condition badge
                  Positioned(
                    top: 12,
                    left: 12,
                    child: _CondBadge(_p.condition),
                  ),
                  // Sold overlay
                  if (_p.status == 'sold')
                    Container(
                      color: Colors.black.withValues(alpha: 0.4),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Text('VENDU',
                            style: GoogleFonts.urbanist(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            )),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── Content ──────────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title + price
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _p.title,
                          style: GoogleFonts.urbanist(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: kMpText,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _fmt(_p.price),
                        style: GoogleFonts.urbanist(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: kMpOrange,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Location + views
                  Row(children: [
                    const Icon(Icons.location_on_rounded,
                        size: 14, color: kMpMuted),
                    const SizedBox(width: 4),
                    Text(_p.city,
                        style: GoogleFonts.urbanist(
                            fontSize: 13, color: kMpMuted)),
                    const SizedBox(width: 16),
                    const Icon(Icons.remove_red_eye_outlined,
                        size: 14, color: kMpMuted),
                    const SizedBox(width: 4),
                    Text('${_p.views} vues',
                        style: GoogleFonts.urbanist(
                            fontSize: 13, color: kMpMuted)),
                  ]),
                ],
              ),
            ),
          ),

          // ── Specs ─────────────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Caractéristiques',
                      style: GoogleFonts.urbanist(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kMpText,
                      )),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _SpecChip(Icons.business_rounded, _p.brand),
                      _SpecChip(Icons.devices_rounded, _catLabel(_p.category)),
                      if (_p.storage != null)
                        _SpecChip(Icons.storage_rounded, _p.storage!),
                      if (_p.ram != null)
                        _SpecChip(Icons.memory_rounded, _p.ram!),
                      if (_p.color != null)
                        _SpecChip(Icons.palette_rounded, _p.color!),
                      if (_p.battery != null)
                        _SpecChip(
                            Icons.battery_charging_full_rounded, _p.battery!),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── Description ───────────────────────────────────────────────────────
          if (_p.description.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Description',
                        style: GoogleFonts.urbanist(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: kMpText,
                        )),
                    const SizedBox(height: 10),
                    Text(
                      _p.description,
                      style: GoogleFonts.urbanist(
                        fontSize: 14,
                        color: const Color(0xFF555555),
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Seller card ───────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Vendeur',
                      style: GoogleFonts.urbanist(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kMpText,
                      )),
                  const SizedBox(height: 12),
                  Row(children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: kMpOrange.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          _p.sellerName.isNotEmpty
                              ? _p.sellerName[0].toUpperCase()
                              : '?',
                          style: GoogleFonts.urbanist(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: kMpOrange,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(
                              _p.sellerName.isEmpty
                                  ? 'Vendeur AZ'
                                  : _p.sellerName,
                              style: GoogleFonts.urbanist(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: kMpText,
                              ),
                            ),
                            if (_p.sellerVerified) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified_rounded,
                                  size: 16, color: Color(0xFF2196F3)),
                            ],
                          ]),
                          if (_p.sellerCity.isNotEmpty)
                            Row(children: [
                              const Icon(Icons.location_on_rounded,
                                  size: 12, color: kMpMuted),
                              const SizedBox(width: 2),
                              Text(_p.sellerCity,
                                  style: GoogleFonts.urbanist(
                                      fontSize: 12, color: kMpMuted)),
                            ]),
                        ],
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),

      // ── Bottom action bar ────────────────────────────────────────────────────
      bottomNavigationBar: _p.status != 'sold'
          ? _ActionBar(product: _p)
          : Container(
              height: 70,
              color: Colors.white,
              alignment: Alignment.center,
              child: Text('Ce produit a été vendu',
                  style: GoogleFonts.urbanist(
                      color: Colors.red, fontWeight: FontWeight.w600)),
            ),
    );
  }

  Widget _imgPlaceholder() => Container(
        color: const Color(0xFFF0F0F0),
        child: const Center(
          child:
              Icon(Icons.devices_rounded, size: 64, color: Color(0xFFBDBDBD)),
        ),
      );

  void _showReport() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ReportSheet(product: _p),
    );
  }

  String _catLabel(String c) {
    switch (c) {
      case 'phones':
        return 'Téléphone';
      case 'tablets':
        return 'Tablette';
      case 'computers':
        return 'Ordinateur';
      case 'accessories':
        return 'Accessoire';
      default:
        return c;
    }
  }
}

// ── Bottom action bar ──────────────────────────────────────────────────────────
class _ActionBar extends StatelessWidget {
  final MpProduct product;
  const _ActionBar({required this.product});

  String get _cleaned => product.sellerPhone.replaceAll(RegExp(r'[^0-9+]'), '');

  Future<void> _openChat(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Connectez-vous pour envoyer un message',
            style: GoogleFonts.urbanist(color: Colors.white)),
        backgroundColor: kMpOrange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    // Fetch buyer name
    String buyerName = 'Acheteur';
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients')
          .doc(user.uid)
          .get();
      buyerName = doc.data()?['name'] ?? buyerName;
    } catch (_) {}

    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MpChatPage(
          product: product,
          buyerId: user.uid,
          buyerName: buyerName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPhone = product.sellerPhone.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x15000000), blurRadius: 20, offset: Offset(0, -4))
        ],
      ),
      child: Row(children: [
        // Call
        if (hasPhone)
          _ActionBtn(
            icon: Icons.phone_rounded,
            label: 'Appeler',
            color: kMpOrange,
            outlined: true,
            onTap: () => launchUrl(Uri.parse('tel:$_cleaned')),
          ),
        if (hasPhone) const SizedBox(width: 8),

        // In-app chat (message + vocal)
        Expanded(
          child: _ActionBtn(
            icon: Icons.chat_rounded,
            label: 'Message',
            color: const Color(0xFF1A1A2E),
            onTap: () => _openChat(context),
          ),
        ),
        const SizedBox(width: 8),

        // WhatsApp
        if (hasPhone)
          Expanded(
            child: _ActionBtn(
              icon: Icons.chat_bubble_rounded,
              label: 'WhatsApp',
              color: const Color(0xFF25D366),
              onTap: () => launchUrl(
                Uri.parse('https://wa.me/$_cleaned'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ),
      ]),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool outlined;
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    if (outlined) {
      return OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label,
            style: GoogleFonts.urbanist(
                fontWeight: FontWeight.w700, fontSize: 13)),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: Colors.white),
      label: Text(label,
          style: GoogleFonts.urbanist(
              fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 13),
      ),
    );
  }
}

// ── Spec chip ──────────────────────────────────────────────────────────────────
class _SpecChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SpecChip(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: kMpOrange),
        const SizedBox(width: 6),
        Text(label,
            style: GoogleFonts.urbanist(
                fontSize: 13, fontWeight: FontWeight.w600, color: kMpText)),
      ]),
    );
  }
}

// ── Condition badge ────────────────────────────────────────────────────────────
class _CondBadge extends StatelessWidget {
  final String condition;
  const _CondBadge(this.condition);

  @override
  Widget build(BuildContext context) {
    final c = conditionColor(condition);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.4), blurRadius: 8)],
      ),
      child: Text(conditionLabel(condition),
          style: GoogleFonts.urbanist(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          )),
    );
  }
}

// ── Report sheet ───────────────────────────────────────────────────────────────
class _ReportSheet extends StatefulWidget {
  final MpProduct product;
  const _ReportSheet({required this.product});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? _selected;
  bool _sending = false;

  final _reasons = [
    'Annonce frauduleuse',
    'Prix incorrect',
    'Produit introuvable',
    'Photos volées',
    'Vendeur irréjoignable',
    'Autre',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Signaler cette annonce',
              style: GoogleFonts.urbanist(
                  fontSize: 16, fontWeight: FontWeight.w700, color: kMpText)),
          const SizedBox(height: 14),
          RadioGroup<String>(
            groupValue: _selected ?? '',
            onChanged: (v) => setState(() => _selected = v),
            child: Column(
              children: _reasons
                  .map((r) => RadioListTile<String>(
                        title:
                            Text(r, style: GoogleFonts.urbanist(fontSize: 14)),
                        value: r,
                        activeColor: Colors.red,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ScaleButton(
              onPressed: (_selected == null || _sending)
                  ? null
                  : () async {
                      setState(() => _sending = true);
                      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                      await MpService.reportProduct(
                          widget.product.id, uid, _selected!);
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Signalement envoyé, merci.',
                              style: GoogleFonts.urbanist(color: Colors.white)),
                          backgroundColor: Colors.red,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      );
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text('Envoyer le signalement',
                      style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

String _fmt(int price) {
  if (price >= 1000000) {
    return '${(price / 1000000).toStringAsFixed(1).replaceAll('.0', '')} M FCFA';
  }
  final s = price.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${buf.toString()} FCFA';
}
