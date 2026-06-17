import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../mp_constants.dart';
import '../models/mp_product.dart';
import '../services/mp_service.dart';
import 'mp_add_product.dart';
import 'mp_product_detail.dart';

class MpSellerScreen extends StatelessWidget {
  const MpSellerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: kMpBg,
      appBar: AppBar(
        title: Text('Mes annonces',
            style: GoogleFonts.inter(
                fontSize: 16, fontWeight: FontWeight.w700, color: kMpText)),
        backgroundColor: Colors.white,
        foregroundColor: kMpText,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MpAddProductScreen()),
            ),
            icon: const Icon(Icons.add_circle_rounded, color: kMpOrange, size: 28),
          ),
        ],
      ),
      body: StreamBuilder<List<MpProduct>>(
        stream: MpService.streamBySeller(uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: kMpOrange));
          }
          final products = snap.data ?? [];

          // Stats
          final active = products.where((p) => p.status == 'active').length;
          final sold   = products.where((p) => p.status == 'sold').length;
          final hidden = products.where((p) => p.status == 'hidden').length;
          final views  = products.fold<int>(0, (s, p) => s + p.views);
          final favs   = products.fold<int>(0, (s, p) => s + p.favoritesCount);

          return Column(
            children: [
              // Stats bar
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                child: Row(children: [
                  _Stat('$active', 'Actif', kMpOrange),
                  _Stat('$sold', 'Vendu', const Color(0xFF4CAF50)),
                  _Stat('$views', 'Vues', const Color(0xFF2196F3)),
                  _Stat('$favs', 'Favoris', Colors.red),
                  if (hidden > 0) _Stat('$hidden', 'Masqué', kMpMuted),
                ]),
              ),

              // Empty state
              if (products.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.storefront_rounded,
                              size: 64, color: kMpMuted),
                          const SizedBox(height: 16),
                          Text('Aucune annonce',
                              style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: kMpText)),
                          const SizedBox(height: 8),
                          Text('Publiez votre premier produit !',
                              style: GoogleFonts.inter(
                                  fontSize: 13, color: kMpMuted)),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const MpAddProductScreen()),
                            ),
                            icon: const Icon(Icons.add_rounded),
                            label: Text('Publier une annonce',
                                style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w700)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kMpOrange,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 14),
                            ),
                          ),
                        ]),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: products.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (_, i) => _SellerProductTile(
                      product: products[i],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const MpAddProductScreen()),
        ),
        backgroundColor: kMpOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text('Nouvelle annonce',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

// ── Stats chip ─────────────────────────────────────────────────────────────────
class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  const _Stat(this.value, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(children: [
        Text(value,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
            )),
        Text(label,
            style: GoogleFonts.inter(fontSize: 11, color: kMpMuted)),
      ]),
    );
  }
}

// ── Seller product tile ────────────────────────────────────────────────────────
class _SellerProductTile extends StatelessWidget {
  final MpProduct product;
  const _SellerProductTile({required this.product});

  @override
  Widget build(BuildContext context) {
    final statusColor = product.status == 'active'
        ? const Color(0xFF4CAF50)
        : product.status == 'sold'
            ? Colors.red
            : kMpMuted;
    final statusLabel = product.status == 'active'
        ? 'Actif'
        : product.status == 'sold'
            ? 'Vendu'
            : 'Masqué';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A000000), blurRadius: 6, offset: Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          // Thumbnail
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MpProductDetail(product: product)),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(14)),
              child: SizedBox(
                width: 90,
                height: 90,
                child: product.images.isNotEmpty
                    ? Image.network(
                        product.images.first,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: kMpBg,
                          child: const Icon(Icons.devices_rounded,
                              color: kMpMuted, size: 32),
                        ),
                      )
                    : Container(
                        color: kMpBg,
                        child: const Icon(Icons.devices_rounded,
                            color: kMpMuted, size: 32),
                      ),
              ),
            ),
          ),

          // Info
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: kMpText,
                        height: 1.3,
                      )),
                  const SizedBox(height: 4),
                  Text(_fmt(product.price),
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: kMpOrange)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(statusLabel,
                          style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: statusColor)),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.remove_red_eye_outlined,
                        size: 11, color: kMpMuted),
                    const SizedBox(width: 2),
                    Text('${product.views}',
                        style:
                            GoogleFonts.inter(fontSize: 11, color: kMpMuted)),
                  ]),
                ],
              ),
            ),
          ),

          // Actions
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: kMpMuted),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            onSelected: (action) =>
                _handleAction(context, action),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'edit',
                child: _MenuItem(Icons.edit_rounded, 'Modifier', kMpOrange),
              ),
              if (product.status == 'active')
                const PopupMenuItem(
                  value: 'sold',
                  child: _MenuItem(
                      Icons.check_circle_rounded, 'Marquer vendu',
                      Color(0xFF4CAF50)),
                ),
              if (product.status == 'sold')
                const PopupMenuItem(
                  value: 'reactivate',
                  child: _MenuItem(
                      Icons.refresh_rounded, 'Réactiver', kMpOrange),
                ),
              if (product.status == 'active')
                const PopupMenuItem(
                  value: 'hide',
                  child: _MenuItem(
                      Icons.visibility_off_rounded, 'Masquer', kMpMuted),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: _MenuItem(
                    Icons.delete_rounded, 'Supprimer', Colors.red),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(BuildContext context, String action) async {
    switch (action) {
      case 'edit':
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => MpAddProductScreen(editProduct: product)),
        );
        break;
      case 'sold':
        await MpService.markSold(product.id);
        break;
      case 'reactivate':
        await MpService.reactivate(product.id);
        break;
      case 'hide':
        await MpService.softDelete(product.id);
        break;
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: Text('Supprimer ?',
                style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
            content: Text(
                'Cette annonce sera masquée définitivement.',
                style: GoogleFonts.inter()),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Supprimer',
                      style: TextStyle(color: Colors.red))),
            ],
          ),
        );
        if (ok == true) await MpService.softDelete(product.id);
        break;
    }
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MenuItem(this.icon, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 10),
      Text(label,
          style:
              GoogleFonts.inter(fontSize: 14, color: color, fontWeight: FontWeight.w600)),
    ]);
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
