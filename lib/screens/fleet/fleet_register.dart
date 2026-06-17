import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class FleetRegister extends StatefulWidget {
  const FleetRegister({super.key});

  @override
  State<FleetRegister> createState() => _FleetRegisterState();
}

class _FleetRegisterState extends State<FleetRegister> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();

  bool _loading = false;
  bool _showPass = false;
  File? _selfieFile;
  File? _idPhotoFile;

  Future<void> _takeSelfie() async {
    final img = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 75,
    );
    if (img != null && mounted) setState(() => _selfieFile = File(img.path));
  }

  Future<void> _pickIdPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 80);
    if (picked != null && mounted) setState(() => _idPhotoFile = File(picked.path));
  }

  void _showIdPhotoSource() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFF6A1B9A)),
              title: const Text("Photographier la pièce d'identité"),
              onTap: () { Navigator.pop(context); _pickIdPhoto(ImageSource.camera); },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Color(0xFF6A1B9A)),
              title: const Text("Importer depuis la galerie"),
              onTap: () { Navigator.pop(context); _pickIdPhoto(ImageSource.gallery); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _register() async {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final id = _idCtrl.text.trim().toLowerCase();
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;

    if (name.isEmpty || phone.isEmpty || id.isEmpty || pass.isEmpty) {
      _snack("Remplissez tous les champs", Colors.red);
      return;
    }
    if (_selfieFile == null) {
      _snack("Veuillez prendre votre photo selfie", Colors.orange);
      return;
    }
    if (pass.length < 6) {
      _snack("Le mot de passe doit avoir au moins 6 caractères", Colors.red);
      return;
    }
    if (pass != confirm) {
      _snack("Les mots de passe ne correspondent pas", Colors.red);
      return;
    }

    setState(() => _loading = true);

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
        email: "$id@az-fleet.ci",
        password: pass,
      );

      final uid = credential.user!.uid;

      // Upload selfie
      final selfieRef = FirebaseStorage.instance
          .ref("fleet_selfies/$uid/selfie.jpg");
      await selfieRef.putFile(_selfieFile!);
      final selfieUrl = await selfieRef.getDownloadURL();

      // Upload pièce d'identité (si fournie)
      String idPhotoUrl = "";
      if (_idPhotoFile != null) {
        final idRef = FirebaseStorage.instance
            .ref("fleet_id_photos/$uid/id.jpg");
        await idRef.putFile(_idPhotoFile!);
        idPhotoUrl = await idRef.getDownloadURL();
      }

      await FirebaseFirestore.instance
          .collection("fleet_owners")
          .doc(uid)
          .set({
        "name": name,
        "phone": phone,
        "identifiant": id,
        "status": "pending",
        "photoUrl": selfieUrl,
        "idPhotoUrl": idPhotoUrl,
        "idNumber": _idNumberCtrl.text.trim(),
        "createdAt": Timestamp.now(),
      });

      await FirebaseAuth.instance.signOut();

      if (!mounted) return;
      setState(() => _loading = false);
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.hourglass_top, color: Color(0xFF6A1B9A)),
              SizedBox(width: 8),
              Text("Demande envoyée"),
            ],
          ),
          content: const Text(
            "Votre demande a été soumise.\n\n"
            "L'administrateur va examiner votre dossier et vous approuver prochainement.\n\n"
            "Une fois approuvé, connectez-vous avec votre identifiant et mot de passe.",
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            ScaleButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6A1B9A),
              ),
              child: const Text("OK", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      return;
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (e.code == 'email-already-in-use') {
        _snack("Cet identifiant est déjà utilisé", Colors.red);
      } else {
        _snack("Erreur : ${e.message}", Colors.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack("Erreur inattendue", Colors.red);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _idCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _idNumberCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Créer un compte Patron"),
        backgroundColor: const Color(0xFF6A1B9A),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                children: [
                  Icon(Icons.motorcycle, size: 60, color: Colors.white),
                  SizedBox(height: 8),
                  Text(
                    "Inscription Patron de Flotte",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── SELFIE OBLIGATOIRE ─────────────────────────
            GestureDetector(
              onTap: _takeSelfie,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _selfieFile != null
                        ? Colors.green
                        : const Color(0xFF6A1B9A),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 8)
                  ],
                ),
                child: _selfieFile == null
                    ? Column(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: const Color(0xFF6A1B9A)
                                  .withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.camera_alt,
                                color: Color(0xFF6A1B9A), size: 36),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "Prendre votre photo selfie",
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: Color(0xFF6A1B9A)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Obligatoire — caméra frontale",
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          ClipOval(
                            child: Image.file(_selfieFile!,
                                width: 100, height: 100, fit: BoxFit.cover),
                          ),
                          const SizedBox(height: 8),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle,
                                  color: Colors.green, size: 18),
                              SizedBox(width: 6),
                              Text("Photo prise",
                                  style: TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                          Text("Appuyez pour reprendre",
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 12)),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: 14),
            _field(_nameCtrl, "Votre nom complet", Icons.person),
            const SizedBox(height: 14),
            _field(_phoneCtrl, "Numéro de téléphone", Icons.phone,
                type: TextInputType.phone),
            const SizedBox(height: 14),
            _field(_idCtrl, "Identifiant (votre ID de connexion)", Icons.badge,
                hint: "ex: patron2024"),
            const SizedBox(height: 14),
            _passField(_passCtrl, "Mot de passe"),
            const SizedBox(height: 14),
            _passField(_confirmCtrl, "Confirmer le mot de passe"),

            const SizedBox(height: 20),

            // ── PIÈCE D'IDENTITÉ ───────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8)
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Pièce d'identité",
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Color(0xFF6A1B9A)),
                  ),
                  const SizedBox(height: 12),
                  _field(_idNumberCtrl, "Numéro de la pièce d'identité",
                      Icons.badge),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: _showIdPhotoSource,
                    child: Container(
                      height: 130,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _idPhotoFile != null
                              ? Colors.green
                              : const Color(0xFF6A1B9A)
                                  .withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _idPhotoFile != null
                            ? Image.file(_idPhotoFile!, fit: BoxFit.cover)
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.credit_card_rounded,
                                      size: 36,
                                      color: const Color(0xFF6A1B9A)
                                          .withValues(alpha: 0.5)),
                                  const SizedBox(height: 8),
                                  const Text(
                                    "Photo de la pièce d'identité",
                                    style: TextStyle(
                                        color: Color(0xFF6A1B9A),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "Appuyez pour prendre ou importer",
                                    style: TextStyle(
                                        color: Colors.grey.shade400,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ScaleButton(
                onPressed: _loading ? null : _register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6A1B9A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "Créer mon compte",
                        style: TextStyle(fontSize: 17, color: Colors.white),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "Votre identifiant et mot de passe vous serviront\npour vous connecter à chaque fois.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type, String? hint}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }

  Widget _passField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      obscureText: !_showPass,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock),
        suffixIcon: IconButton(
          icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _showPass = !_showPass),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}
