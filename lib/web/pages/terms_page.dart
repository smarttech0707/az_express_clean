import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebTermsPage extends StatelessWidget {
  const WebTermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNavy,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(children: [
              const SizedBox(height: 72),
              _header(context),
              _body(context),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/conditions'),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 60),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(children: [
        Text("Conditions Générales d'Utilisation",
            style: GoogleFonts.inter(
                fontSize: isDesktop(ctx) ? 40 : 26,
                fontWeight: FontWeight.w700,
                color: kWhite),
            textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text('Dernière mise à jour : 9 juillet 2026',
            style: GoogleFonts.inter(fontSize: 14, color: kTextMuted)),
      ]),
    );
  }

  Widget _body(BuildContext ctx) {
    final docWidth = isDesktop(ctx) ? 800.0 : double.infinity;
    return Center(
      child: Container(
        width: docWidth,
        padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 60),
        child: const Column(children: [
          _Section(
              '1. Acceptation des conditions',
              'En téléchargeant, installant ou utilisant l\'application AZ Express ou en accédant à '
                  'notre site web az-express.ci, vous acceptez d\'être lié par les présentes Conditions '
                  'Générales d\'Utilisation. Si vous n\'acceptez pas ces conditions, veuillez ne pas '
                  'utiliser nos services.'),
          _Section(
              '2. Description des services',
              'AZ Express est une plateforme technologique qui met en relation :\n\n'
                  '• Des clients souhaitant recevoir des livraisons ou des services\n'
                  '• Des livreurs indépendants partenaires\n'
                  '• Des commerçants, restaurants et prestataires de services\n\n'
                  'AZ Express agit en tant qu\'intermédiaire technologique et n\'est pas directement '
                  'responsable de la livraison physique des marchandises.'),
          _Section(
              '3. Création de compte',
              'Pour utiliser AZ Express, vous devez :\n\n'
                  '• Avoir au moins 16 ans\n'
                  '• Fournir un numéro de téléphone valide\n'
                  '• Fournir des informations exactes et à jour\n'
                  '• Maintenir la confidentialité de vos identifiants\n\n'
                  'Vous êtes responsable de toutes les activités effectuées depuis votre compte. '
                  'Tout usage non autorisé doit être signalé immédiatement.'),
          _Section(
              '4. Utilisation des services',
              'En utilisant AZ Express, vous vous engagez à :\n\n'
                  '• Utiliser les services uniquement à des fins légales\n'
                  '• Ne pas commander de biens illégaux ou dangereux\n'
                  '• Fournir des adresses de livraison exactes\n'
                  '• Être disponible lors de la livraison\n'
                  '• Traiter les livreurs et partenaires avec respect\n'
                  '• Ne pas abuser du système d\'annulation\n\n'
                  'AZ Express se réserve le droit de suspendre ou supprimer tout compte '
                  'en cas d\'abus ou de violation de ces conditions.'),
          _Section(
              '5. Commandes et paiements',
              'Lors d\'une commande :\n\n'
                  '• Le prix affiché est définitif avant confirmation\n'
                  '• Le paiement peut être effectué par mobile money (Wave, MTN, Orange, Moov) ou en espèces\n'
                  '• Les paiements sont traités de manière sécurisée via FeexPay\n'
                  '• En cas d\'annulation après acceptation par le livreur, des frais peuvent s\'appliquer\n'
                  '• Les remboursements sont traités sous 48 heures ouvrables'),
          _Section(
              '6. Wallet et solde',
              'Le wallet AZ Express :\n\n'
                  '• Peut être rechargé via mobile money (FeexPay)\n'
                  '• Le solde est valable 12 mois à compter de la dernière transaction\n'
                  '• N\'est pas remboursable en espèces sauf cas exceptionnel\n'
                  '• Les transactions sont irréversibles après confirmation\n'
                  '• AZ Express n\'est pas une institution financière'),
          _Section(
              '7. Responsabilités',
              'AZ Express n\'est pas responsable :\n\n'
                  '• Des dommages subis lors de la livraison dus à la négligence du client\n'
                  '• Des retards dus à des conditions hors de notre contrôle (embouteillages, météo)\n'
                  '• De la qualité des produits fournis par les commerçants partenaires\n'
                  '• Des actions des livreurs indépendants partenaires\n\n'
                  'Toutefois, en cas de problème, notre équipe s\'engage à trouver une solution satisfaisante.'),
          _Section(
              '8. Livreurs partenaires',
              'Les livreurs utilisant la plateforme AZ Express :\n\n'
                  '• Sont des prestataires indépendants, non des employés\n'
                  '• Sont responsables de leur véhicule et de leur assurance\n'
                  '• Doivent respecter le code de conduite AZ Express\n'
                  '• Peuvent être déréférencés en cas de comportement inapproprié'),
          _Section(
              '9. Propriété intellectuelle',
              'L\'ensemble des éléments d\'AZ Express (logo, design, code, contenu) sont la '
                  'propriété exclusive d\'AZ Express. Toute reproduction, modification ou utilisation '
                  'sans autorisation est interdite.'),
          _Section(
              '10. Droit applicable',
              'Les présentes conditions sont régies par le droit ivoirien. '
                  'Tout litige sera soumis à la juridiction compétente d\'Abidjan, '
                  'Côte d\'Ivoire, après tentative de résolution amiable.'),
          _Section(
              '11. Modifications',
              'AZ Express se réserve le droit de modifier ces conditions à tout moment. '
                  'Les modifications vous seront notifiées via l\'application ou par email. '
                  'L\'utilisation continue des services après notification vaut acceptation.'),
          _Section(
              '12. Contact',
              'Pour toute question relative à ces conditions :\n\n'
                  'Email : legal@az-express.ci\n'
                  'Adresse : Abidjan, Côte d\'Ivoire\n'
                  'WhatsApp : +225 07 98 05 13 97'),
        ]),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String content;
  const _Section(this.title, this.content);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.inter(
                  fontSize: 18, fontWeight: FontWeight.w700, color: kWhite)),
          const SizedBox(height: 12),
          Text(content,
              style: GoogleFonts.inter(
                  fontSize: 15, color: kTextMuted, height: 1.8)),
          const Divider(color: kDivider, height: 48),
        ],
      ),
    );
  }
}
