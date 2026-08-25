import 'package:flutter/material.dart';

/// Jetons visuels réservés à AZ IA. Ils ne remplacent pas le thème global
/// d'AZ Express et évitent de propager ce style sombre aux autres modules.
abstract final class AzIaTheme {
  static const night = Color(0xFF0D1117);
  static const deepBlue = Color(0xFF0D1117);
  static const surface = Color(0xFF161B22);
  static const surfaceSoft = Color(0xFF1E1E1E);
  static const electricBlue = Color(0xFF1976D2);
  static const azOrange = Color(0xFFFF6A00);
  static const azOrangeLight = Color(0xFFFF8C21);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFE5E7EB);
  static const textPlaceholder = Color(0xFF9CA3AF);
  static const border = Color(0xFF2A3340);
  static const online = Color(0xFF65D57A);

  static const spacing8 = 8.0;
  static const spacing12 = 12.0;
  static const spacing16 = 16.0;
  static const spacing20 = 20.0;
  static const spacing24 = 24.0;
  static const spacing32 = 32.0;

  static const cardRadius = BorderRadius.all(Radius.circular(20));
  static const bubbleRadius = BorderRadius.all(Radius.circular(20));
  static const inputRadius = BorderRadius.all(Radius.circular(28));
  static const pillRadius = BorderRadius.all(Radius.circular(30));

  static const fast = Duration(milliseconds: 180);
  static const normal = Duration(milliseconds: 280);
  static const ambient = Duration(milliseconds: 1400);

  static const backgroundGradient = LinearGradient(
    colors: [night, deepBlue, Color(0xFF0B1424)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const iaButtonGradient = LinearGradient(
    colors: [Color(0xFF101B31), Color(0xFF081020)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
