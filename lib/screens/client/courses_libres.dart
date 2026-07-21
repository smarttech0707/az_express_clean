import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/order_model.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_theme.dart';

class CoursesLibres extends StatefulWidget {
  const CoursesLibres({super.key});

  @override
  State<CoursesLibres> createState() => _CoursesLibresState();
}

class _CoursesLibresState extends State<CoursesLibres> {
  final _descCtrl = TextEditingController();
  final _budgetCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _descCtrl.dispose();
    _budgetCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOrder() async {
    final desc = _descCtrl.text.trim();
    final budgetText = _budgetCtrl.text.trim();

    if (desc.isEmpty || budgetText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Remplissez tous les champs"),
            backgroundColor: Colors.red),
      );
      return;
    }

    final budget = int.tryParse(budgetText);
    if (budget == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Budget invalide"), backgroundColor: Colors.red),
      );
      return;
    }
    if (budget < 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Budget minimum : 500 FCFA (frais de livraison inclus)"),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _sending = true);

    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Permission de localisation refusée")),
          );
        }
        setState(() => _sending = false);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));

      final user = FirebaseAuth.instance.currentUser;

      final order = OrderModel(
        id:          const Uuid().v4(),
        description: desc,
        budget:      budget,
        status:      "pending",
        latitude:    position.latitude,
        longitude:   position.longitude,
        type:        "shopping",
        clientId:    user?.uid,
        isPaid:      false,
      );

      await FirestoreService().createOrder(order);

      if (!mounted) return;
      _descCtrl.clear();
      _budgetCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Course envoyée avec succès"),
            backgroundColor: Colors.green),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur : $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Nouvelle course"),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      backgroundColor: const Color(0xFFF5F5F5),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: "Décrire la course",
                hintText: "Ex: Acheter du pain, du lait...",
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.shopping_basket),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _budgetCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: "Budget total (minimum 500 FCFA)",
                hintText:  "Ex: 1000 (livraison + achats)",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled:     true,
                fillColor:  Colors.white,
                prefixIcon: const Icon(Icons.account_balance_wallet),
                suffixText: "FCFA",
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed: _sending ? null : _sendOrder,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.send, color: Colors.white),
                label: Text(
                  _sending ? "Envoi..." : "Envoyer la course",
                  style: const TextStyle(fontSize: 16, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}