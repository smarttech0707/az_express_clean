import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

class PharmacieRegister extends StatefulWidget {
  const PharmacieRegister({super.key});

  @override
  State<PharmacieRegister> createState() => _PharmacieRegisterState();
}

class _PharmacieRegisterState extends State<PharmacieRegister> {
  final _ownerCtrl   = TextEditingController();
  final _nameCtrl    = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _latCtrl     = TextEditingController();
  final _lngCtrl     = TextEditingController();

  bool _loading    = false;
  bool _gpsLoading = false;

  @override
  void dispose() {
    _ownerCtrl.dispose(); _nameCtrl.dispose(); _phoneCtrl.dispose();
    _addressCtrl.dispose(); _latCtrl.dispose(); _lngCtrl.dispose();
    super.dispose();
  }

  Future<void> _captureGPS() async {
    setState(() => _gpsLoading = true);
    try {
      await Geolocator.requestPermission();
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      if (mounted) {
        setState(() {
          _latCtrl.text = pos.latitude.toStringAsFixed(6);
          _lngCtrl.text = pos.longitude.toStringAsFixed(6);
        });
      }
    } catch (_) {
      if (mounted) _snack('Impossible de récupérer la position GPS', Colors.red);
    } finally {
      if (mounted) setState(() => _gpsLoading = false);
    }
  }

  Future<void> _submit() async {
    final owner   = _ownerCtrl.text.trim();
    final name    = _nameCtrl.text.trim();
    final phone   = _phoneCtrl.text.trim().replaceAll(' ', '');
    final address = _addressCtrl.text.trim();

    if (owner.isEmpty || name.isEmpty || phone.isEmpty || address.isEmpty) {
      _snack('Veuillez remplir tous les champs obligatoires', Colors.orange);
      return;
    }

    setState(() => _loading = true);

    try {
      final existing = await FirebaseFirestore.instance
          .collection('pharmacie_requests')
          .doc(phone)
          .get();

      if (existing.exists) {
        if (!mounted) return;
        _snack('Ce numéro a déjà une demande en cours.', Colors.orange);
        return;
      }

      await FirebaseFirestore.instance
          .collection('pharmacie_requests')
          .doc(phone)
          .set({
        'ownerName':     owner,
        'pharmacieName': name,
        'phone':         phone,
        'address':       address,
        'lat':           double.tryParse(_latCtrl.text) ?? 0.0,
        'lng':           double.tryParse(_lngCtrl.text) ?? 0.0,
        'status':        'pending',
        'createdAt':     FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      _snack('Demande envoyée ! L\'admin va valider votre pharmacie.', Colors.green);
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context);
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
    final red = Colors.red.shade700;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Inscription Pharmacie',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        backgroundColor: red,
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
                gradient: LinearGradient(
                    colors: [Colors.red.shade800, Colors.red.shade500]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(children: [
                const Icon(Icons.local_pharmacy_rounded, size: 52, color: Colors.white),
                const SizedBox(height: 10),
                Text('Rejoignez AZ Express',
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Votre pharmacie référencée à Abengourou',
                    style: GoogleFonts.inter(
                        color: Colors.white70, fontSize: 12)),
              ]),
            ),

            const SizedBox(height: 24),
            _section('Informations personnelles'),
            const SizedBox(height: 10),
            _field(_ownerCtrl, 'Votre nom complet *', Icons.person_outline, red),
            const SizedBox(height: 12),
            _field(_phoneCtrl, 'Numéro de téléphone *', Icons.phone_outlined, red,
                type: TextInputType.phone),

            const SizedBox(height: 20),
            _section('Votre pharmacie'),
            const SizedBox(height: 10),
            _field(_nameCtrl, 'Nom de la pharmacie *', Icons.local_pharmacy_outlined, red),
            const SizedBox(height: 12),
            _field(_addressCtrl, 'Adresse *', Icons.location_on_outlined, red),
            const SizedBox(height: 12),

            Row(children: [
              Expanded(
                child: _field(_latCtrl, 'Latitude', Icons.gps_fixed, red,
                    type: const TextInputType.numberWithOptions(
                        decimal: true, signed: true)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _field(_lngCtrl, 'Longitude', Icons.gps_not_fixed, red,
                    type: const TextInputType.numberWithOptions(
                        decimal: true, signed: true)),
              ),
            ]),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _gpsLoading ? null : _captureGPS,
              icon: _gpsLoading
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.my_location_rounded, color: red),
              label: Text(
                _gpsLoading ? 'Localisation...' : 'Utiliser ma position GPS',
                style: TextStyle(color: red),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: red),
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),

            const SizedBox(height: 28),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _loading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: red,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text('Envoyer ma demande',
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),

            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, color: red, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Votre demande sera examinée par l\'admin sous 24h. '
                    'L\'admin vous communiquera vos identifiants de connexion après approbation.',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade800),
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
        style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade600),
      );

  Widget _field(TextEditingController ctrl, String label, IconData icon, Color color,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: color),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}

