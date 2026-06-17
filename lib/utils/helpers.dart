import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants/app_constants.dart';

// ═══════════════════════════════════════════════════════════════════════════
// FORMATAGE MONTANTS
// ═══════════════════════════════════════════════════════════════════════════
class AmountHelper {
  AmountHelper._();

  static String format(int amount) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(1)} M';
    }
    if (amount >= 1000) {
      final thousands = amount ~/ 1000;
      final remainder = (amount % 1000).toString().padLeft(3, '0');
      return '$thousands $remainder';
    }
    return amount.toString();
  }

  static String formatWithCurrency(int amount) => '${format(amount)} FCFA';

  static String formatCompact(int amount) {
    if (amount >= 1000000) return '${(amount / 1000000).toStringAsFixed(1)}M F';
    if (amount >= 1000)    return '${(amount / 1000).toStringAsFixed(0)}K F';
    return '$amount F';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FORMATAGE DATES
// ═══════════════════════════════════════════════════════════════════════════
class DateHelper {
  DateHelper._();

  static String formatFull(DateTime d) =>
      DateFormat('dd/MM/yyyy  HH:mm', 'fr').format(d);

  static String formatDate(DateTime d) =>
      DateFormat('dd/MM/yyyy', 'fr').format(d);

  static String formatTime(DateTime d) =>
      DateFormat('HH:mm', 'fr').format(d);

  static String formatRelative(DateTime d) {
    final now  = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1)  return 'À l\'instant';
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours   < 24) return 'Il y a ${diff.inHours}h';
    if (diff.inDays    < 7)  return 'Il y a ${diff.inDays}j';
    return formatDate(d);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CALCULS GÉOGRAPHIQUES
// ═══════════════════════════════════════════════════════════════════════════
class GeoHelper {
  GeoHelper._();

  static double distanceKm(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) *
            sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _rad(double deg) => deg * pi / 180;

  static String formatDistance(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  static int etaMinutes(double km, {double speedKmh = 30}) =>
      (km / speedKmh * 60).ceil();

  static String formatEta(double km) {
    final min = etaMinutes(km);
    if (min < 60) return '$min min';
    return '${min ~/ 60}h ${min % 60}min';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// VALIDATION
// ═══════════════════════════════════════════════════════════════════════════
class Validators {
  Validators._();

  static bool isValidPhone(String phone) {
    final clean = phone.replaceAll(RegExp(r'[\s\-\+]'), '');
    return RegExp(r'^\d{8,15}$').hasMatch(clean);
  }

  static bool isValidAmount(int amount, {int min = 100}) => amount >= min;

  static bool isValidName(String name) => name.trim().length >= 2;

  static String? validatePhone(String? val) {
    if (val == null || val.isEmpty) return 'Numéro requis';
    if (!isValidPhone(val)) return 'Numéro invalide (8-15 chiffres)';
    return null;
  }

  static String? validateAmount(String? val, {int min = 100}) {
    if (val == null || val.isEmpty) return 'Montant requis';
    final n = int.tryParse(val.replaceAll(' ', ''));
    if (n == null) return 'Montant invalide';
    if (n < min)   return 'Minimum ${AmountHelper.formatWithCurrency(min)}';
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SNACKBAR & DIALOGS
// ═══════════════════════════════════════════════════════════════════════════
class UiHelper {
  UiHelper._();

  static void snack(
    BuildContext context,
    String msg, {
    Color color = const Color(0xFF1A1A2E),
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      duration: duration,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  static void success(BuildContext context, String msg) =>
      snack(context, msg, color: const Color(0xFF2E7D32));

  static void error(BuildContext context, String msg) =>
      snack(context, msg, color: const Color(0xFFC62828));

  static void warning(BuildContext context, String msg) =>
      snack(context, msg, color: const Color(0xFFFF8F00));

  static Future<bool?> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel  = 'Confirmer',
    String cancelLabel   = 'Annuler',
    Color  confirmColor  = const Color(0xFFFF6D00),
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelLabel,
                style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: confirmColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(confirmLabel,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TARIFICATION
// ═══════════════════════════════════════════════════════════════════════════
class PricingHelper {
  PricingHelper._();

  static int deliveryFare(double distanceKm) =>
      DeliveryPricing.calculate(distanceKm);

  static int commission(int fare) =>
      (fare * DeliveryPricing.commissionRate).round();

  static int driverEarning(int fare) => fare - commission(fare);
}

// ═══════════════════════════════════════════════════════════════════════════
// COLLECTION SELON RÔLE
// ═══════════════════════════════════════════════════════════════════════════
class CollectionHelper {
  CollectionHelper._();

  static String forRole(String role) {
    switch (role) {
      case UserRole.driver:      return Collections.livreurs;
      case UserRole.seller:      return Collections.sellers;
      case UserRole.restaurant:  return Collections.restaurants;
      case UserRole.boulangerie: return Collections.boulangeries;
      case UserRole.pharmacie:   return Collections.pharmacies;
      case UserRole.fleet:       return Collections.fleetOwners;
      default:                   return Collections.clients;
    }
  }
}
