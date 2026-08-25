import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';
import '../../constants/app_constants.dart';
import '../../services/account_deletion_service.dart';

/// Page publique /delete-account — point d'entrée web requis par la politique
/// Google Play "Account deletion" : toute app permettant la création de compte
/// doit offrir un moyen de demander la suppression du compte et des données,
/// accessible aussi depuis le web sans réinstaller l'application. Couvre les
/// 9 rôles réels de l'app via AccountDeletionService.submitRequest().
class WebDeleteAccountPage extends StatelessWidget {
  const WebDeleteAccountPage({super.key});

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
              _DeleteAccountBody(),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/delete-account'),
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
        Text('Suppression de compte AZ Express',
            style: kH1Style(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(
            'Demandez la suppression de votre compte et de vos données, sans avoir besoin de réinstaller l\'application.',
            style: GoogleFonts.inter(fontSize: 15, color: kTextMuted),
            textAlign: TextAlign.center),
      ]),
    );
  }
}

class _DeleteAccountBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final docWidth = isDesktop(context) ? 800.0 : double.infinity;
    return Center(
      child: Container(
        width: docWidth,
        padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _InfoBlock(
              title: 'Procédure',
              body:
                  'Renseignez le formulaire ci-dessous avec le rôle de votre compte '
                  '(client, livreur, vendeur, restaurant, pharmacie, boulangerie, agent '
                  'Ekbine, agent immobilier ou patron de flotte) et le numéro de téléphone '
                  'associé à votre compte AZ Express. Votre demande est transmise à notre '
                  'équipe, qui désactive votre compte dès réception de la demande.',
            ),
            const _InfoBlock(
              title: 'Délai de traitement',
              body:
                  'Votre compte est désactivé sous 48 heures ouvrables suivant la demande. '
                  'Vos données personnelles sont ensuite effacées sous 30 jours, sauf '
                  'obligation légale de conservation (ex. historique des transactions '
                  'financières, conservé le temps requis par la réglementation applicable). '
                  'Les clients peuvent aussi supprimer leur compte instantanément depuis '
                  'l\'application (Profil > Supprimer mon compte).',
            ),
            _InfoBlock(
              title: 'Contact support',
              body: 'Pour toute question sur votre demande de suppression : '
                  '${AppConfig.supportEmail} ou WhatsApp +225 07 98 05 13 97.',
            ),
            const SizedBox(height: 24),
            const _DeleteAccountForm(),
          ],
        ),
      ),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  final String title;
  final String body;
  const _InfoBlock({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.inter(
                  fontSize: 17, fontWeight: FontWeight.w700, color: kWhite)),
          const SizedBox(height: 8),
          Text(body,
              style: GoogleFonts.inter(
                  fontSize: 14, color: kTextMuted, height: 1.7)),
        ],
      ),
    );
  }
}

class _DeleteAccountForm extends StatefulWidget {
  const _DeleteAccountForm();

  @override
  State<_DeleteAccountForm> createState() => _DeleteAccountFormState();
}

class _DeleteAccountFormState extends State<_DeleteAccountForm> {
  final _formKey = GlobalKey<FormState>();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  String _role = 'client';
  bool _loading = false;
  bool _success = false;
  String? _error;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AccountDeletionService.submitRequest(
        role: _role,
        contactPhone: _phoneCtrl.text.trim(),
        contactEmail: _emailCtrl.text.trim(),
        reason: _reasonCtrl.text.trim(),
        requestedVia: 'web',
      );
      setState(() {
        _loading = false;
        _success = true;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Une erreur est survenue. Réessayez ou contactez le support.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: glassCard(radius: 24),
      child: _success ? _successView() : _formView(),
    );
  }

  Widget _successView() {
    return Column(children: [
      const Icon(Icons.check_circle_rounded, color: kSuccess, size: 56)
          .animate()
          .scale(duration: 600.ms, curve: Curves.elasticOut),
      const SizedBox(height: 20),
      Text('Demande envoyée',
          style: GoogleFonts.inter(
              fontSize: 22, fontWeight: FontWeight.w700, color: kWhite),
          textAlign: TextAlign.center),
      const SizedBox(height: 10),
      Text(
        'Votre compte sera désactivé sous 48 heures ouvrables. '
        'Vous recevrez une confirmation par téléphone.',
        style: GoogleFonts.inter(fontSize: 14, color: kTextMuted),
        textAlign: TextAlign.center,
      ),
    ]);
  }

  Widget _formView() {
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Demande de suppression',
            style: GoogleFonts.inter(
                fontSize: 20, fontWeight: FontWeight.w700, color: kWhite)),
        const SizedBox(height: 24),
        DropdownButtonFormField<String>(
          initialValue: _role,
          decoration: const InputDecoration(labelText: 'Type de compte'),
          dropdownColor: kNavyCard,
          style: GoogleFonts.inter(color: kWhite, fontSize: 15),
          items: AccountDeletionService.roleLabels.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) => setState(() => _role = v ?? 'client'),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          style: GoogleFonts.inter(color: kWhite, fontSize: 15),
          validator: (v) => (v?.trim().isEmpty ?? true) ? 'Obligatoire' : null,
          decoration: const InputDecoration(
            labelText: 'Numéro de téléphone du compte',
            prefixIcon: Icon(Icons.phone_rounded, color: kTextMuted, size: 20),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          style: GoogleFonts.inter(color: kWhite, fontSize: 15),
          decoration: const InputDecoration(
            labelText: 'Email (optionnel)',
            prefixIcon: Icon(Icons.email_rounded, color: kTextMuted, size: 20),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _reasonCtrl,
          maxLines: 3,
          style: GoogleFonts.inter(color: kWhite, fontSize: 15),
          decoration: const InputDecoration(
            labelText: 'Raison (optionnel)',
            alignLabelWithHint: true,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: GoogleFonts.inter(color: Colors.redAccent, fontSize: 13)),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: kWhite,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: kWhite, strokeWidth: 2))
                : Text('Demander la suppression de mon compte',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}
