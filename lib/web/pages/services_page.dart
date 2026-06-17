import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebServicesPage extends StatelessWidget {
  const WebServicesPage({super.key});

  static const _services = [
    (
      Icons.delivery_dining_rounded,
      'Livraison Express',
      kOrange,
      'Envoyez ou recevez colis, documents et cadeaux en 30 minutes. Standard 500F · Cadeau 700F · Document 300F · Grand colis 1 000F.',
      ['Suivi GPS en temps réel', 'Preuve de livraison photo', 'Colis & Cadeaux', 'Livraison 7j/7'],
    ),
    (
      Icons.shopping_cart_rounded,
      'Courses & Shopping',
      kBlue,
      'Faites vos courses sans vous déplacer. Épicerie, supermarché, marché local — votre coursier fait tout pour vous.',
      ['Listes personnalisées', 'Prix du marché', 'Rapport d\'achat', 'Courses urgentes'],
    ),
    (
      Icons.restaurant_rounded,
      'Restaurants & Fast-Food',
      Color(0xFFE91E63),
      'Commandez vos plats préférés depuis les meilleurs restaurants d\'Abengourou. Livraison chaude garantie.',
      ['Menu en temps réel', 'Suivi commande', 'Note et avis', 'Paiement intégré'],
    ),
    (
      Icons.bakery_dining_rounded,
      'Boulangerie & Café',
      Color(0xFF795548),
      'Pain frais, viennoiseries et café du matin. Commandez aussi des gâteaux personnalisés pour vos événements.',
      ['Commande à l\'avance', 'Gâteaux sur commande', 'Café & boissons', 'Pâtisseries fraîches'],
    ),
    (
      Icons.local_pharmacy_rounded,
      'Pharmacie de Garde',
      kSuccess,
      'Urgence médicale ou simple ordonnance — trouvez la pharmacie de garde la plus proche et recevez vos médicaments.',
      ['Disponible 24h/24', 'Pharmacies de garde', 'Urgences médicales', 'Produits parapharmaceutiques'],
    ),
    (
      Icons.build_rounded,
      'Artisans & Réparations',
      Color(0xFF9C27B0),
      'Plombier, électricien, réparateur téléphone, carreleur — trouvez un artisan qualifié et disponible rapidement.',
      ['Devis instantané', 'Artisans vérifiés', 'Garantie prestation', 'Paiement sécurisé'],
    ),
    (
      Icons.home_rounded,
      'Immobilier',
      Color(0xFF00BCD4),
      'Location de maisons, studios et résidences meublées à Abengourou. Annonces vérifiées.',
      ['Annonces vérifiées', 'Résidences meublées', 'Contact direct', 'Abengourou & CI'],
    ),
    (
      Icons.directions_car_rounded,
      'Taxi de nuit & Tricycle',
      Color(0xFFFF5722),
      'Taxi de nuit & location de tricycle — déplacez-vous en sécurité à Abengourou. Tarifs transparents.',
      ['Taxi nocturne', 'Tricycle disponible', 'Tarif fixe', 'Paiement mobile'],
    ),
    (
      Icons.local_laundry_service_rounded,
      'Blanchisserie',
      Color(0xFF3F51B5),
      'Déposez vos vêtements le matin, récupérez-les propres et repassés le soir. Tarif : 1 000 FCFA/kg.',
      ['Collecte & livraison', 'Lavage & repassage', 'Traitement délicat', '1 000 FCFA/kg'],
    ),
    (
      Icons.local_drink_rounded,
      'Eau & Boissons',
      Color(0xFF2196F3),
      'Commandez vos bidons d\'eau, boissons et softs en quelques clics. Livraison immédiate chez vous.',
      ['Eau en bonbonne', 'Boissons froides', 'Commande régulière', 'Livraison express'],
    ),
    (
      Icons.storefront_rounded,
      'Boutique',
      Color(0xFF9C27B0),
      'Parcourez les boutiques locales d\'Abengourou et commandez leurs produits. Les commerçants gèrent leur stock et traitent vos commandes en temps réel.',
      ['Commerçants locaux', 'Stock en temps réel', 'Paiement sécurisé', 'Livraison express'],
    ),
    (
      Icons.shopping_bag_rounded,
      'Courses Libres',
      Color(0xFF3F51B5),
      'Pas de liste de courses prédéfinie ? Envoyez un livreur faire vos achats librement au marché ou en boutique. Il achète ce que vous demandez et vous livre.',
      ['Marché local', 'Liste personnalisée', 'Photos des articles', 'Livreur dédié'],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Scaffold(
      backgroundColor: kNavy,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(children: [
              const SizedBox(height: 72),
              // Page header
              Container(
                padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
                decoration: const BoxDecoration(gradient: kHeroGradient),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: kOrange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('NOS SERVICES',
                        style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700,
                          color: kOrange, letterSpacing: 1.2)),
                    ).animate().fadeIn(duration: 600.ms),
                    const SizedBox(height: 16),
                    Text('Tout ce dont vous avez besoin',
                      style: kDisplayStyle(context),
                      textAlign: TextAlign.center,
                    ).animate(delay: 200.ms).fadeIn(duration: 700.ms),
                    const SizedBox(height: 14),
                    Text('Une seule application, des dizaines de services disponibles 24h/24.',
                      style: GoogleFonts.inter(fontSize: 16, color: kTextMuted, height: 1.6),
                      textAlign: TextAlign.center,
                    ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
                  ],
                ),
              ),
              // Services list
              Padding(
                padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
                child: Column(
                  children: _services.asMap().entries.map((e) {
                    final s = e.value;
                    final i = e.key;
                    return _ServiceRow(
                      icon: s.$1, title: s.$2, color: s.$3,
                      desc: s.$4, features: s.$5,
                      reversed: desk && i.isOdd,
                      delay: (i * 100).ms,
                    );
                  }).toList(),
                ),
              ),
              // Payment methods section
              _PaymentSection(),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0, left: 0, right: 0,
            child: WebNavBar(currentRoute: '/services'),
          ),
        ],
      ),
    );
  }
}

class _PaymentSection extends StatelessWidget {
  static const _operators = [
    ('assets/payment/orange.png', 'Orange Money'),
    ('assets/payment/moov.png', 'Moov Money'),
    ('assets/payment/mtn.png', 'MTN Mobile Money'),
    ('assets/payment/wave.png', 'Wave'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      decoration: BoxDecoration(
        color: kWhite.withValues(alpha: 0.03),
        border: const Border(top: BorderSide(color: Color(0x1AFFFFFF))),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('PAIEMENT MOBILE',
              style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700,
                color: kOrange, letterSpacing: 1.2)),
          ).animate().fadeIn(duration: 600.ms),
          const SizedBox(height: 16),
          Text('Payez facilement avec votre opérateur',
            style: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w700, color: kWhite),
            textAlign: TextAlign.center,
          ).animate(delay: 150.ms).fadeIn(duration: 600.ms),
          const SizedBox(height: 10),
          Text('Orange Money, Moov Money, MTN Mobile Money, Wave — tous les opérateurs acceptés.',
            style: GoogleFonts.inter(fontSize: 15, color: kTextMuted, height: 1.6),
            textAlign: TextAlign.center,
          ).animate(delay: 250.ms).fadeIn(duration: 600.ms),
          const SizedBox(height: 48),
          Wrap(
            spacing: 24,
            runSpacing: 24,
            alignment: WrapAlignment.center,
            children: _operators.asMap().entries.map((e) {
              final i = e.key;
              final op = e.value;
              return _OperatorCard(
                assetPath: op.$1,
                name: op.$2,
                delay: (i * 100).ms,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _OperatorCard extends StatelessWidget {
  final String assetPath;
  final String name;
  final Duration delay;

  const _OperatorCard({required this.assetPath, required this.name, required this.delay});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kWhite.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kWhite.withValues(alpha: 0.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(assetPath, width: 80, height: 80, fit: BoxFit.contain),
          ),
          const SizedBox(height: 12),
          Text(name,
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: kTextMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ).animate(delay: delay).fadeIn(duration: 600.ms).slideY(begin: 0.1);
  }
}

class _ServiceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final String desc;
  final List<String> features;
  final bool reversed;
  final Duration delay;

  const _ServiceRow({
    required this.icon, required this.title, required this.color,
    required this.desc, required this.features,
    required this.reversed, required this.delay,
  });

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 48),
      child: desk
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: reversed
                  ? [Expanded(child: _textSide(context)), const SizedBox(width: 48), Expanded(child: _iconSide())]
                  : [Expanded(child: _iconSide()), const SizedBox(width: 48), Expanded(child: _textSide(context))],
            )
          : Column(children: [_iconSide(), const SizedBox(height: 24), _textSide(context)]),
    ).animate(delay: delay).fadeIn(duration: 600.ms).slideY(begin: 0.1);
  }

  Widget _iconSide() {
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Center(
        child: Icon(icon, color: color, size: 80),
      ),
    );
  }

  Widget _textSide(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Text(title, style: GoogleFonts.inter(
            fontSize: 22, fontWeight: FontWeight.w700, color: kWhite)),
        ]),
        const SizedBox(height: 16),
        Text(desc, style: GoogleFonts.inter(fontSize: 15, color: kTextMuted, height: 1.7)),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: features.map((f) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_rounded, color: color, size: 12),
              const SizedBox(width: 6),
              Text(f, style: GoogleFonts.inter(fontSize: 12, color: color)),
            ]),
          )).toList(),
        ),
      ],
    );
  }
}
