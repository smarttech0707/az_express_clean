import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../artisan/artisan_login.dart';
import '../driver/driver_login.dart';
import '../fleet/fleet_login.dart';
import '../seller/seller_login.dart';
import '../restaurant/restaurant_owner_login.dart';
import '../pharmacie/pharmacie_login.dart';
import '../boulangerie/boulangerie_login.dart';
import '../../theme/app_theme.dart';

class ProPortal extends StatelessWidget {
  const ProPortal({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Espace Professionnel',
          style: GoogleFonts.urbanist(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 17),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.business_center_rounded,
                        color: AppColors.primary, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Accès réservé aux partenaires',
                            style: GoogleFonts.urbanist(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14)),
                        Text(
                            'Comptes créés par l\'administrateur AZ Express uniquement.',
                            style: GoogleFonts.urbanist(
                                color: Colors.white54,
                                fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            Text(
              'Choisissez votre espace',
              style: GoogleFonts.urbanist(
                  color: Colors.white54,
                  fontSize: 12,
                  letterSpacing: 1.2),
            ),
            const SizedBox(height: 14),

            // Cartes services pro
            _ProCard(
              icon: Icons.handyman_rounded,
              title: 'Artisan / Mécanicien',
              subtitle: 'Gérez vos photos de réalisations',
              gradient: const [Color(0xFF1565C0), Color(0xFF1976D2)],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ArtisanLogin())),
            ),
            const SizedBox(height: 12),
            _ProCard(
              icon: Icons.delivery_dining_rounded,
              title: 'Livreur',
              subtitle: 'Accédez à votre espace courses',
              gradient: const [Color(0xFF0D47A1), Color(0xFF1976D2)],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DriverLogin())),
            ),
            const SizedBox(height: 12),
            _ProCard(
              icon: Icons.storefront_rounded,
              title: 'Boutique / Vendeur',
              subtitle: 'Gérez vos produits et commandes',
              gradient: const [Color(0xFF1565C0), Color(0xFF1E88E5)],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SellerLogin())),
            ),
            const SizedBox(height: 12),
            _ProCard(
              icon: Icons.restaurant_rounded,
              title: 'Restaurant',
              subtitle: 'Gérez votre menu et vos commandes',
              gradient: const [Color(0xFF1565C0), Color(0xFF1E88E5)],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const RestaurantOwnerLogin())),
            ),
            const SizedBox(height: 12),
            _ProCard(
              icon: Icons.motorcycle_rounded,
              title: 'Patron de Flotte',
              subtitle: 'Gérez vos livreurs et vos gains',
              gradient: const [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const FleetLogin())),
            ),
            const SizedBox(height: 12),
            _ProCard(
              icon: Icons.local_pharmacy_rounded,
              title: 'Pharmacie',
              subtitle: 'Gérez votre statut de garde et wallet',
              gradient: [Colors.red.shade800, Colors.red.shade500],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PharmacieLogin())),
            ),
            const SizedBox(height: 12),
            _ProCard(
              icon: Icons.bakery_dining_rounded,
              title: 'Boulangerie / Café',
              subtitle: 'Gérez votre menu et vos commandes',
              gradient: const [Color(0xFF4E342E), Color(0xFF8D6E63)],
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const BoulangerieLogin())),
            ),

            const SizedBox(height: 32),

            Center(
              child: Text(
                'AZ Express — Abengourou',
                style: GoogleFonts.urbanist(
                    color: Colors.white24, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ProCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> gradient;
  final VoidCallback onTap;

  const _ProCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.onTap,
  });

  @override
  State<_ProCard> createState() => _ProCardState();
}

class _ProCardState extends State<_ProCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.gradient,
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: widget.gradient.first.withValues(alpha: 0.35),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(widget.icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    Text(widget.subtitle,
                        style: GoogleFonts.urbanist(
                            color: Colors.white70,
                            fontSize: 12)),
                  ],
                ),
              ),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_forward_ios,
                    color: Colors.white, size: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
