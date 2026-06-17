import 'package:flutter/material.dart';

/// Logo AZ Express — carré orange arrondi avec "AZ" en blanc.
/// N'utilise pas Google Fonts pour éviter le flash au chargement web.
class AzLogo extends StatelessWidget {
  final double size;
  const AzLogo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFFF6B00),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: Center(
        child: Text(
          'AZ',
          style: TextStyle(
            fontFamily: 'Arial',
            package: null,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: -0.5,
            height: 1,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
