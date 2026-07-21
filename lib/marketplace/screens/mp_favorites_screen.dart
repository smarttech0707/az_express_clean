import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../mp_constants.dart';
import '../services/mp_service.dart';
import '../models/mp_product.dart';
import '../widgets/mp_product_card.dart';

class MpFavoritesScreen extends StatefulWidget {
  const MpFavoritesScreen({super.key});

  @override
  State<MpFavoritesScreen> createState() => _MpFavoritesScreenState();
}

class _MpFavoritesScreenState extends State<MpFavoritesScreen> {
  List<MpProduct>? _products;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _products = []);
      return;
    }
    final list = await MpService.getFavoriteProducts(uid);
    if (mounted) setState(() => _products = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kMpBg,
      appBar: AppBar(
        title: Text('Mes favoris',
            style: GoogleFonts.urbanist(
                fontSize: 16, fontWeight: FontWeight.w700, color: kMpText)),
        backgroundColor: Colors.white,
        foregroundColor: kMpText,
        elevation: 0,
        centerTitle: true,
      ),
      body: _products == null
          ? const Center(child: CircularProgressIndicator(color: kMpOrange))
          : _products!.isEmpty
              ? Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                      const Icon(Icons.favorite_border_rounded,
                          size: 64, color: kMpMuted),
                      const SizedBox(height: 16),
                      Text('Aucun favori',
                          style: GoogleFonts.urbanist(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: kMpText)),
                      const SizedBox(height: 8),
                      Text('Appuyez sur ❤️ pour sauvegarder des annonces',
                          style: GoogleFonts.urbanist(
                              fontSize: 13, color: kMpMuted),
                          textAlign: TextAlign.center),
                    ]))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.68,
                  ),
                  itemCount: _products!.length,
                  itemBuilder: (_, i) =>
                      MpProductCard(product: _products![i]),
                ),
    );
  }
}
