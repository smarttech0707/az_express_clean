import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../../widgets/scale_button.dart';
import '../../services/auth_service.dart';

class DriverRegister extends StatefulWidget {
  const DriverRegister({super.key});

  @override
  State<DriverRegister> createState() => _DriverRegisterState();
}

class _DriverRegisterState extends State<DriverRegister> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();

  bool _loading = false;
  bool _showPass = false;
  Uint8List? _selfieBytes;
  Uint8List? _idPhotoBytes;
  bool _acceptTerms = false;
  bool _acceptRemuneration = false;

  Future<void> _takeSelfie() async {
    try {
      final img = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 55,
        maxWidth: 800,
      );
      if (img != null && mounted) {
        final bytes = await img.readAsBytes();
        setState(() => _selfieBytes = bytes);
      }
    } catch (e) {
      if (mounted)
        _snack("Impossible d'accéder à la caméra. Vérifiez les permissions.",
            Colors.red);
    }
  }

  Future<void> _pickIdPhoto(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 60,
        maxWidth: 1024,
      );
      if (picked != null && mounted) {
        final bytes = await picked.readAsBytes();
        setState(() => _idPhotoBytes = bytes);
      }
    } catch (e) {
      if (mounted)
        _snack(
            "Impossible d'accéder à la caméra/galerie. Vérifiez les permissions.",
            Colors.red);
    }
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF167DB7)),
              title: const Text("Photographier la pièce d'identité"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF167DB7)),
              title: const Text("Importer depuis la galerie"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.gallery);
              },
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

    final email = _emailCtrl.text.trim();

    if (name.isEmpty ||
        phone.isEmpty ||
        email.isEmpty ||
        id.isEmpty ||
        pass.isEmpty) {
      _snack("Remplissez tous les champs", Colors.red);
      return;
    }
    if (!AuthService.isValidEmail(email)) {
      _snack("Adresse email invalide", Colors.orange);
      return;
    }
    if (!AuthService.isValidPhone(phone)) {
      _snack("Numéro de téléphone invalide", Colors.orange);
      return;
    }
    if (_selfieBytes == null) {
      _snack("Veuillez prendre votre photo selfie", Colors.orange);
      return;
    }
    final passErr = AuthService.validatePassword(pass);
    if (passErr != null) {
      _snack(passErr, Colors.red);
      return;
    }
    if (pass != confirm) {
      _snack("Les mots de passe ne correspondent pas", Colors.red);
      return;
    }
    if (!_acceptTerms) {
      _snack("Veuillez accepter les conditions d'utilisation", Colors.orange);
      return;
    }
    if (!_acceptRemuneration) {
      _snack("Veuillez accepter la politique de rémunération", Colors.orange);
      return;
    }

    setState(() => _loading = true);

    try {
      // Utiliser le vrai email comme identifiant Firebase Auth
      final credential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: pass,
      );

      final uid = credential.user!.uid;

      // Upload selfie
      final ref = FirebaseStorage.instance
          .ref()
          .child("driver_selfies/$uid/selfie.jpg");
      await ref.putData(
        _selfieBytes!,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final photoUrl = await ref.getDownloadURL();

      // Upload pièce d'identité (si fournie)
      String idPhotoUrl = "";
      if (_idPhotoBytes != null) {
        final idRef = FirebaseStorage.instance
            .ref()
            .child("driver_id_photos/$uid/id.jpg");
        await idRef.putData(
          _idPhotoBytes!,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        idPhotoUrl = await idRef.getDownloadURL();
      }

      // Envoyer demande d'approbation
      await FirebaseFirestore.instance
          .collection("driver_requests")
          .doc(uid)
          .set({
        "uid": uid,
        "name": name,
        "phone": phone,
        "email": email,
        "identifiant": id,
        "status": "pending",
        "photoUrl": photoUrl,
        "idPhotoUrl": idPhotoUrl,
        "idNumber": _idNumberCtrl.text.trim(),
        "createdAt": FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      setState(() => _loading = false);

      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instance.signInAnonymously();

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.hourglass_empty, color: Colors.orange),
              SizedBox(width: 8),
              Text("Demande envoyée"),
            ],
          ),
          content: const Text(
            "Votre demande a été transmise à l'administrateur.\n\n"
            "Vous pourrez vous connecter dès qu'il l'aura approuvée.",
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            ScaleButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF167DB7),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text("OK"),
            ),
          ],
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      switch (e.code) {
        case 'email-already-in-use':
          _snack("Cet identifiant est déjà utilisé", Colors.red);
        case 'network-request-failed':
          _snack(
              "Pas de connexion internet. Vérifiez votre réseau et réessayez.",
              Colors.orange);
        case 'too-many-requests':
          _snack("Trop de tentatives. Réessayez dans quelques minutes.",
              Colors.orange);
        case 'weak-password':
          _snack("Mot de passe trop faible (6 caractères minimum)", Colors.red);
        default:
          _snack("Erreur d'inscription : ${e.message}", Colors.red);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      final msg = e.toString();
      if (msg.contains('network') ||
          msg.contains('timeout') ||
          msg.contains('SocketException')) {
        _snack("Connexion internet instable. Réessayez.", Colors.orange);
      } else {
        _snack("Erreur : $msg", Colors.red);
      }
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  void _showLegal(BuildContext context, String title, String content) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(title, style: const TextStyle(fontSize: 15)),
            backgroundColor: const Color(0xFF167DB7),
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Text(content,
                style: const TextStyle(fontSize: 14, height: 1.8)),
          ),
        ),
      ),
    );
  }

  static const String _termsDriver =
      """CONDITIONS D'UTILISATION DES LIVREURS — AZ Express

Dernière mise à jour : 2026

Les présentes conditions définissent les règles applicables aux livreurs utilisant l'application AZ Express.

1. INSCRIPTION

Le livreur doit :
• Fournir des informations exactes
• Avoir un numéro de téléphone valide
• Disposer d'un moyen de déplacement (moto, vélo, voiture)

2. ACCEPTATION DES COURSES

• Le livreur est libre d'accepter ou refuser une course
• Une fois acceptée, il doit effectuer la livraison correctement

3. OBLIGATIONS DU LIVREUR

Le livreur s'engage à :
• Être ponctuel
• Respecter les clients
• Ne pas annuler abusivement les commandes
• Livrer les produits en bon état

4. COMPORTEMENT INTERDIT

Il est interdit de :
• Voler ou détourner une commande
• Demander un paiement supplémentaire non autorisé
• Fournir de fausses informations

5. PAIEMENT DES LIVREURS

• Les gains sont calculés selon les livraisons effectuées
• Le paiement peut se faire selon les modalités définies par AZ Express

6. SUSPENSION DU COMPTE

AZ Express peut suspendre un livreur en cas de :
• Mauvais comportement
• Fraude
• Non-respect des règles

7. RESPONSABILITÉ

Le livreur est responsable de ses actions pendant les livraisons.""";

  static const String _remuneration = """RÉMUNÉRATION DES LIVREURS — AZ Express

PRINCIPE

Le livreur reçoit une commission sur chaque livraison effectuée avec succès.

MOYENS DE PAIEMENT

• En espèces (remise directe)
• Via Mobile Money (Orange Money, MTN MoMo…)

COMMISSION

AZ Express peut prélever une commission sur chaque course. Le montant net perçu par le livreur est affiché dans son portefeuille.

CALENDRIER DE PAIEMENT

Les paiements sont effectués selon un calendrier défini :
• Journalier (selon activité)
• Hebdomadaire
• Sur demande du livreur

RETARDS

En cas de retard de paiement, le livreur peut contacter le support :
Email : znm0905@gmail.com""";

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
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
        title: const Text("Créer un compte livreur"),
        backgroundColor: const Color(0xFF167DB7),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF167DB7), Color(0xFF1E88E5)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                children: [
                  Icon(Icons.delivery_dining, size: 60, color: Colors.white),
                  SizedBox(height: 8),
                  Text("Inscription Livreur",
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text(
                    "Votre demande sera examinée\npar l'administrateur",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
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
                    color: _selfieBytes != null
                        ? Colors.green
                        : const Color(0xFF167DB7),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 8)
                  ],
                ),
                child: _selfieBytes == null
                    ? Column(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: const Color(0xFF167DB7)
                                  .withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.camera_alt,
                                color: Color(0xFF167DB7), size: 36),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "Prendre votre photo selfie",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Color(0xFF167DB7),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Obligatoire — utilisée pour vérifier\nvotre identité lors des livraisons",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          ClipOval(
                            child: Image.memory(
                              _selfieBytes!,
                              width: 100,
                              height: 100,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle,
                                  color: Colors.green, size: 18),
                              SizedBox(width: 6),
                              Text(
                                "Photo prise",
                                style: TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Appuyez pour reprendre la photo",
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12),
                          ),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: 16),

            _field(_nameCtrl, "Nom complet", Icons.person),
            const SizedBox(height: 12),
            _field(_phoneCtrl, "Numéro de téléphone", Icons.phone,
                type: TextInputType.phone, hint: "ex: 0701234567"),
            const SizedBox(height: 12),
            _field(_emailCtrl, "Adresse email", Icons.email_outlined,
                type: TextInputType.emailAddress, hint: "exemple@email.com"),
            const SizedBox(height: 12),
            _field(_idCtrl, "Identifiant de connexion", Icons.badge,
                hint: "ex: ali2024"),
            const SizedBox(height: 12),
            _passField(_passCtrl, "Mot de passe"),
            const SizedBox(height: 12),
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
                        color: Color(0xFF167DB7)),
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
                          color: _idPhotoBytes != null
                              ? Colors.green
                              : const Color(0xFF167DB7).withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _idPhotoBytes != null
                            ? Image.memory(_idPhotoBytes!, fit: BoxFit.cover)
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.credit_card_rounded,
                                      size: 36,
                                      color: const Color(0xFF167DB7)
                                          .withValues(alpha: 0.5)),
                                  const SizedBox(height: 8),
                                  const Text(
                                    "Photo de la pièce d'identité",
                                    style: TextStyle(
                                        color: Color(0xFF167DB7),
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

            const SizedBox(height: 20),

            // ── ACCEPTATION ────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: (!_acceptTerms || !_acceptRemuneration)
                      ? Colors.grey.shade200
                      : Colors.green.shade300,
                ),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 8)
                ],
              ),
              child: Column(
                children: [
                  CheckboxListTile(
                    value: _acceptTerms,
                    onChanged: (v) => setState(() => _acceptTerms = v ?? false),
                    activeColor: const Color(0xFF167DB7),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black87),
                        children: [
                          const TextSpan(text: "J'accepte les "),
                          WidgetSpan(
                            child: GestureDetector(
                              onTap: () => _showLegal(
                                  context, "Conditions livreurs", _termsDriver),
                              child: const Text(
                                "Conditions d'utilisation livreur",
                                style: TextStyle(
                                  color: Color(0xFF167DB7),
                                  decoration: TextDecoration.underline,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  CheckboxListTile(
                    value: _acceptRemuneration,
                    onChanged: (v) =>
                        setState(() => _acceptRemuneration = v ?? false),
                    activeColor: const Color(0xFF167DB7),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black87),
                        children: [
                          const TextSpan(text: "J'accepte la "),
                          WidgetSpan(
                            child: GestureDetector(
                              onTap: () => _showLegal(context,
                                  "Rémunération des livreurs", _remuneration),
                              child: const Text(
                                "Politique de rémunération",
                                style: TextStyle(
                                  color: Color(0xFF167DB7),
                                  decoration: TextDecoration.underline,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ScaleButton(
                onPressed: _loading ? null : _register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF167DB7),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text("Envoyer la demande",
                        style: TextStyle(fontSize: 17, color: Colors.white)),
              ),
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
