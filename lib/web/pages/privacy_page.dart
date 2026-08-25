import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebPrivacyPage extends StatelessWidget {
  const WebPrivacyPage({super.key});

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
            child: WebNavBar(currentRoute: '/confidentialite'),
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
        Text('Politique de Confidentialité',
            style: kH1Style(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text('Dernière mise à jour : 9 juillet 2026',
            style: GoogleFonts.inter(fontSize: 14, color: kTextMuted)),
      ]),
    );
  }

  Widget _body(BuildContext ctx) {
    final pad = hPad(ctx);
    final docWidth = isDesktop(ctx) ? 800.0 : double.infinity;
    return Center(
      child: Container(
        width: docWidth,
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: 60),
        child: const Column(children: [
          _Section(
              '1. Introduction',
              'AZ Express ("nous", "notre", "nos") s\'engage à protéger la vie privée de ses utilisateurs. '
                  'La présente Politique de Confidentialité explique comment nous collectons, utilisons, '
                  'divulguons et protégeons vos informations personnelles lorsque vous utilisez notre '
                  'application mobile AZ Express et notre site web az-express.ci.'),
          _Section(
              '2. Informations collectées',
              'Nous collectons les informations suivantes :\n\n'
                  '• Informations d\'identification : nom, prénom, numéro de téléphone\n'
                  '• Informations de localisation : position GPS en temps réel (uniquement lors de l\'utilisation)\n'
                  '• Informations de commande : adresses de livraison, historique des commandes\n'
                  '• Informations de paiement : données de transaction (non stockées localement)\n'
                  '• Données techniques : identifiant d\'appareil, tokens de notification push\n'
                  '• Communications : messages avec le support client'),
          _Section(
              '3. Utilisation des données',
              'Vos données sont utilisées pour :\n\n'
                  '• Traiter et suivre vos commandes en temps réel\n'
                  '• Connecter clients, livreurs et commerçants\n'
                  '• Envoyer des notifications sur l\'état de vos commandes\n'
                  '• Améliorer nos services et l\'expérience utilisateur\n'
                  '• Assurer la sécurité et prévenir les fraudes\n'
                  '• Respecter nos obligations légales\n'
                  '• Vous contacter en cas de besoin relatif à votre compte'),
          _Section(
              '4. Partage des données',
              'Nous ne vendons jamais vos données personnelles à des tiers. '
                  'Nous pouvons partager vos informations avec :\n\n'
                  '• Nos livreurs partenaires (uniquement nom et adresse de livraison)\n'
                  '• Nos commerçants partenaires (commande et coordonnées pour livraison)\n'
                  '• Firebase/Google (infrastructure cloud sécurisée)\n'
                  '• FeexPay (traitement sécurisé des paiements mobile money)\n'
                  '• Anthropic (fournisseur de l\'assistant intelligent AZ IA — uniquement le texte '
                  'nécessaire au traitement de votre demande, voir section 9 ci-dessous)\n'
                  '• Autorités judiciaires (uniquement si requis par la loi)'),
          _Section(
              '5. Localisation',
              'L\'application AZ Express utilise votre localisation GPS pour :\n\n'
                  '• Trouver les services disponibles près de vous\n'
                  '• Permettre aux livreurs de vous trouver\n'
                  '• Calculer les prix et délais de livraison\n\n'
                  'Vous pouvez désactiver la localisation dans les paramètres de votre téléphone, '
                  'mais certaines fonctionnalités seront alors limitées.'),
          _Section(
              '6. Sécurité',
              'Nous protégeons vos données grâce à :\n\n'
                  '• Chiffrement en transit (HTTPS/TLS)\n'
                  '• Firebase Security Rules avancées\n'
                  '• Authentification sécurisée\n'
                  '• Accès limité aux données (principe du moindre privilège)\n'
                  '• Surveillance continue des accès anormaux\n\n'
                  'Malgré ces mesures, aucun système n\'est infaillible. '
                  'Nous vous encourageons à protéger votre mot de passe.'),
          _Section(
              '7. Conservation des données',
              'Nous conservons vos données aussi longtemps que votre compte est actif. '
                  'Après suppression de compte, vos données sont effacées sous 30 jours, '
                  'sauf obligation légale de conservation.'),
          _Section(
              '8. Vos droits',
              'Conformément aux lois applicables, vous avez le droit de :\n\n'
                  '• Accéder à vos données personnelles\n'
                  '• Corriger des informations inexactes\n'
                  '• Supprimer votre compte et vos données\n'
                  '• Vous opposer au traitement de vos données\n'
                  '• Retirer votre consentement\n\n'
                  'Pour exercer ces droits, contactez-nous à : privacy@az-express.ci\n\n'
                  'Pour demander la suppression de votre compte, utilisez le menu de l\'application '
                  '(Profil > Supprimer mon compte) ou notre page dédiée : az-express.ci/delete-account.'),
          _Section(
              '9. Assistant intelligent AZ IA',
              'AZ Express propose un assistant conversationnel intelligent (« AZ IA ») pour vous aider '
                  'à effectuer vos commandes et répondre à vos questions.\n\n'
                  '• AZ IA fait appel à un fournisseur d\'intelligence artificielle externe, Anthropic '
                  '(modèle Claude), pour comprendre et répondre à vos demandes\n'
                  '• Seul le texte nécessaire au traitement de votre demande (votre message, et si vous '
                  'utilisez la fonction vocale, sa transcription) est transmis à ce fournisseur\n'
                  '• Ces données ne sont jamais vendues, ni utilisées à des fins publicitaires\n'
                  '• L\'objectif unique de ce traitement est de vous assister dans l\'utilisation de '
                  'l\'application (suivi de commande, aide à la commande, réponses à vos questions)\n'
                  '• Aucune action financière ou destructrice (paiement, retrait, remboursement, suppression) '
                  'n\'est jamais exécutée par AZ IA sans votre confirmation explicite\n'
                  '• Vous pouvez à tout moment consulter, exporter ou effacer votre historique de conversation '
                  'avec AZ IA depuis le menu de la conversation dans l\'application'),
          _Section(
              '10. Notifications Push',
              'Avec votre consentement, nous envoyons des notifications push pour :\n'
                  '• Le statut de vos commandes en temps réel\n'
                  '• Les confirmations de paiement\n'
                  '• Les alertes de sécurité\n\n'
                  'Vous pouvez désactiver les notifications dans les paramètres de votre appareil.'),
          _Section(
              '11. Mineurs',
              'Nos services sont destinés aux personnes âgées de 16 ans et plus. '
                  'Nous ne collectons pas sciemment de données concernant des mineurs. '
                  'Si vous pensez qu\'un mineur utilise nos services, contactez-nous.'),
          _Section(
              '12. Modifications',
              'Nous pouvons modifier cette politique à tout moment. '
                  'Les modifications importantes vous seront notifiées via l\'application. '
                  'La date de dernière mise à jour est indiquée en haut de ce document.'),
          _Section(
              '13. Contact',
              'Pour toute question relative à cette politique de confidentialité :\n\n'
                  'Email : privacy@az-express.ci\n'
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
