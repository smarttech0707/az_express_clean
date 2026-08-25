import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../utils/partner_location_validator.dart';
import '../../widgets/partner_location_input.dart';

class BoulangerieRegister extends StatefulWidget {
  const BoulangerieRegister({super.key});

  @override
  State<BoulangerieRegister> createState() => _BoulangerieRegisterState();
}

class _BoulangerieRegisterState extends State<BoulangerieRegister> {
  final _ownerCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;

  static const _brown = Color(0xFF5D4037);

  @override
  void dispose() {
    _ownerCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _passCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final owner = _ownerCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim().replaceAll(' ', '');
    final address = _addressCtrl.text.trim();
    final pass = _passCtrl.text;

    if (owner.isEmpty ||
        name.isEmpty ||
        phone.isEmpty ||
        address.isEmpty ||
        pass.isEmpty) {
      _snack('Veuillez remplir tous les champs obligatoires', Colors.orange);
      return;
    }
    if (pass.length < 6) {
      _snack('Mot de passe minimum 6 caractères', Colors.orange);
      return;
    }
    final locationError =
        PartnerLocationValidator.validateText(_latCtrl.text, _lngCtrl.text);
    if (locationError != null) {
      _snack(locationError, Colors.orange);
      return;
    }

    setState(() => _loading = true);

    try {
      final current = FirebaseAuth.instance.currentUser;
      if (current != null && current.isAnonymous) {
        await FirebaseAuth.instance.signOut();
      }

      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: '$phone@az-boulangerie.ci',
        password: pass,
      );
      final uid = cred.user!.uid;

      await FirebaseFirestore.instance
          .collection('boulangerie_requests')
          .doc(uid)
          .set({
        'uid': uid,
        'ownerName': owner,
        'boulangerieName': name,
        'phone': phone,
        'address': address,
        'lat': double.parse(_latCtrl.text.trim()),
        'lng': double.parse(_lngCtrl.text.trim()),
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await FirebaseAuth.instance.signOut();
      try {
        await FirebaseAuth.instance.signInAnonymously();
      } catch (_) {}

      if (!mounted) return;
      _snack('Demande envoyée ! L\'admin va valider votre boulangerie.',
          Colors.green);
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'email-already-in-use') {
        _snack('Ce numéro est déjà enregistré.', Colors.red);
      } else {
        _snack('Erreur : ${e.message}', Colors.red);
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Inscription Boulangerie',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        backgroundColor: _brown,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF4E342E), Color(0xFF8D6E63)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(children: [
                const Icon(Icons.bakery_dining_rounded,
                    size: 52, color: Colors.white),
                const SizedBox(height: 10),
                Text('Rejoignez AZ Express',
                    style: GoogleFonts.urbanist(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Votre boulangerie livrée à Abengourou',
                    style: GoogleFonts.urbanist(
                        color: Colors.white70, fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 24),
            _section('Informations personnelles'),
            const SizedBox(height: 10),
            _field(_ownerCtrl, 'Votre nom complet *', Icons.person_outline),
            const SizedBox(height: 12),
            _field(_phoneCtrl, 'Numéro de téléphone *', Icons.phone_outlined,
                type: TextInputType.phone),
            const SizedBox(height: 20),
            _section('Votre boulangerie'),
            const SizedBox(height: 10),
            _field(_nameCtrl, 'Nom de la boulangerie *', Icons.store_outlined),
            const SizedBox(height: 12),
            _field(_addressCtrl, 'Adresse *', Icons.location_on_outlined),
            const SizedBox(height: 12),
            PartnerLocationInput(
              latitudeController: _latCtrl,
              longitudeController: _lngCtrl,
            ),
            const SizedBox(height: 20),
            _section('Mot de passe de connexion'),
            const SizedBox(height: 10),
            TextField(
              controller: _passCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Mot de passe (min. 6 caractères) *',
                prefixIcon: const Icon(Icons.lock_outline, color: _brown),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: Colors.grey,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: _brown, width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _loading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _brown,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text('Envoyer ma demande',
                        style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.brown.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.brown.shade200),
              ),
              child: Row(children: [
                Icon(Icons.info_outline,
                    color: Colors.brown.shade700, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Votre demande sera examinée par l\'admin sous 24h. '
                    'Notez votre numéro et mot de passe pour vous connecter après approbation.',
                    style:
                        TextStyle(fontSize: 12, color: Colors.brown.shade800),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Text(
        title,
        style: GoogleFonts.urbanist(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade600),
      );

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: _brown),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _brown, width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}
