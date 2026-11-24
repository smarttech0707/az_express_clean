import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/mp_product.dart';
import '../mp_constants.dart';
import '../providers/mp_favorites_provider.dart';
import '../screens/mp_product_detail.dart';

// ── Grid card (portrait) ───────────────────────────────────────────────────────
class MpProductCard extends StatelessWidget {
  final MpProduct product;
  const MpProductCard({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MpProductDetail(product: product)),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: kMpCard,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image + badges
            Expanded(
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(16)),
                    child: _ProductImage(product.images),
                  ),
                  // Condition badge
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _ConditionBadge(product.condition),
                  ),
                  // Favorite button
                  Positioned(
                    top: 4,
                    right: 4,
                    child: _FavButton(productId: product.id),
                  ),
                  // VIP badge
                  if (product.sellerVipStatus == 'active')
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD700),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('👑 VIP',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: Colors.black87)),
                      ),
                    ),
                  // Sold overlay
                  if (product.status == 'sold')
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16)),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.45),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('VENDU',
                                style: GoogleFonts.urbanist(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                )),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Info
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.urbanist(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: kMpText,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fmt(product.price),
                    style: GoogleFonts.urbanist(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: kMpOrange,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.location_on_rounded,
                        size: 11, color: kMpMuted),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        product.city,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            GoogleFonts.urbanist(fontSize: 11, color: kMpMuted),
                      ),
                    ),
                    if (product.sellerVerified)
                      const Icon(Icons.verified_rounded,
                          size: 12, color: Color(0xFF2196F3)),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Horizontal card (landscape) ────────────────────────────────────────────────
class MpProductTile extends StatelessWidget {
  final MpProduct product;
  const MpProductTile({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MpProductDetail(product: product)),
      ),
      child: Container(
        width: 180,
        decoration: BoxDecoration(
          color: kMpCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0E000000), blurRadius: 8, offset: Offset(0, 2))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(14)),
                  child: SizedBox(
                    height: 120,
                    width: double.infinity,
                    child: _ProductImage(product.images),
                  ),
                ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: _ConditionBadge(product.condition, small: true),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: _FavButton(productId: product.id, small: true),
                ),
                if (product.sellerVipStatus == 'active')
                  Positioned(
                    bottom: 4,
                    left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFD700),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('👑 VIP',
                          style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              color: Colors.black87)),
                    ),
                  ),
                if (product.sellerVerified)
                  const Positioned(
                    bottom: 4,
                    right: 4,
                    child: Icon(Icons.verified_rounded,
                        size: 16, color: Color(0xFF2196F3)),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.urbanist(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: kMpText,
                          height: 1.3)),
                  const SizedBox(height: 3),
                  Text(_fmt(product.price),
                      style: GoogleFonts.urbanist(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: kMpOrange)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Private helpers ────────────────────────────────────────────────────────────

class _ProductImage extends StatelessWidget {
  final List<String> images;
  const _ProductImage(this.images);

  @override
  Widget build(BuildContext context) {
    if (images.isNotEmpty) {
      return Image.network(
        images.first,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _placeholder(),
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : _shimmer(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
        color: const Color(0xFFF0F0F0),
        child: const Center(
          child:
              Icon(Icons.devices_rounded, size: 36, color: Color(0xFFBDBDBD)),
        ),
      );

  Widget _shimmer() => Container(
        color: const Color(0xFFF0F0F0),
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: kMpOrange,
            ),
          ),
        ),
      );
}

class _ConditionBadge extends StatelessWidget {
  final String condition;
  final bool small;
  const _ConditionBadge(this.condition, {this.small = false});

  @override
  Widget build(BuildContext context) {
    final color = conditionColor(condition);
    final label = conditionLabel(condition);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 6 : 8,
        vertical: small ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Text(
        label,
        style: GoogleFonts.urbanist(
          fontSize: small ? 9 : 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _FavButton extends StatelessWidget {
  final String productId;
  final bool small;
  const _FavButton({required this.productId, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Consumer<MpFavoritesProvider>(
      builder: (_, fav, __) {
        final isFav = fav.isFav(productId);
        return GestureDetector(
          onTap: () async {
            await fav.load();
            await fav.toggle(productId);
          },
          child: Container(
            width: small ? 28 : 32,
            height: small ? 28 : 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(color: Color(0x1A000000), blurRadius: 4)
              ],
            ),
            child: Icon(
              isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: isFav ? Colors.red : kMpMuted,
              size: small ? 14 : 16,
            ),
          ),
        );
      },
    );
  }
}

String _fmt(int price) {
  if (price >= 1000000) {
    return '${(price / 1000000).toStringAsFixed(1).replaceAll('.0', '')} M FCFA';
  }
  if (price >= 1000) {
    final s = price.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return '${buf.toString()} FCFA';
  }
  return '$price FCFA';
}
