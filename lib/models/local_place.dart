import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../theme/app_theme.dart';

/// Lieu local stocké dans Firestore (collection `places`).
class LocalPlace {
  final String id;
  final String name;
  final String category;
  final String district;
  final String address;
  final double latitude;
  final double longitude;
  final String? cityId;
  final String normalizedName;
  final List<String> aliases;
  final List<String> keywords;
  final int searchCount;
  final bool verified;
  final String source; // 'firestore' | 'osm' | 'google'

  LocalPlace({
    required this.id,
    required this.name,
    required this.category,
    required this.district,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.cityId,
    String? normalizedName,
    this.aliases = const [],
    this.keywords = const [],
    this.searchCount = 0,
    this.verified = false,
    this.source = 'firestore',
  }) : normalizedName = normalizedName ?? normalize(name);

  bool get hasCoords => latitude != 0 || longitude != 0;
  LatLng get latLng => LatLng(latitude, longitude);

  // ── Normalisation canonique des noms géographiques ─────────────────────
  static String normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[éèêëēėę]'), 'e')
      .replaceAll(RegExp('[àáâäãåā]'), 'a')
      .replaceAll(RegExp('[òóôöõō]'), 'o')
      .replaceAll(RegExp('[ùúûüū]'), 'u')
      .replaceAll(RegExp('[ìíîïī]'), 'i')
      .replaceAll(RegExp('[ýÿ]'), 'y')
      .replaceAll('ç', 'c')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp("[’‘`´']"), ' ')
      .replaceAll(RegExp(r'[‐‑‒–—−-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String get nameNorm => normalizedName;

  // ── Icône selon catégorie ───────────────────────────────────────────────
  IconData get icon {
    switch (category) {
      case 'hotel':
      case 'auberge':
        return Icons.hotel_rounded;
      case 'pharmacie':
        return Icons.local_pharmacy_rounded;
      case 'hopital':
      case 'clinique':
      case 'chu':
        return Icons.local_hospital_rounded;
      case 'ecole':
      case 'lycee':
      case 'college':
        return Icons.school_rounded;
      case 'restaurant':
      case 'maquis':
      case 'cafeteria':
        return Icons.restaurant_rounded;
      case 'station':
      case 'carburant':
        return Icons.local_gas_station_rounded;
      case 'mosquee':
        return Icons.mosque_rounded;
      case 'eglise':
        return Icons.church_rounded;
      case 'marche':
        return Icons.storefront_rounded;
      case 'banque':
      case 'atm':
        return Icons.account_balance_rounded;
      case 'administration':
      case 'mairie':
        return Icons.account_balance_rounded;
      case 'gare':
      case 'bus':
        return Icons.directions_bus_rounded;
      case 'quartier':
        return Icons.location_city_rounded;
      case 'carrefour':
        return Icons.roundabout_right_rounded;
      default:
        return Icons.place_rounded;
    }
  }

  // ── Couleur selon catégorie ─────────────────────────────────────────────
  Color get color {
    switch (category) {
      case 'hotel':
      case 'auberge':
        return const Color(0xFF1565C0);
      case 'pharmacie':
        return Colors.red;
      case 'hopital':
      case 'clinique':
      case 'chu':
        return Colors.red.shade700;
      case 'ecole':
      case 'lycee':
      case 'college':
        return Colors.orange;
      case 'restaurant':
      case 'maquis':
        return Colors.deepOrange;
      case 'station':
        return const Color(0xFF2E7D32);
      case 'mosquee':
        return Colors.teal;
      case 'eglise':
        return Colors.purple;
      case 'marche':
        return Colors.amber.shade700;
      case 'banque':
        return Colors.indigo;
      case 'quartier':
        return const Color(0xFF37474F);
      default:
        return AppColors.primary;
    }
  }

  // ── Désérialisation Firestore ───────────────────────────────────────────
  factory LocalPlace.fromMap(String id, Map<String, dynamic> d) {
    return LocalPlace(
      id: id,
      name: d['name'] as String? ?? '',
      category: d['category'] as String? ?? 'other',
      district: d['district'] as String? ?? '',
      address: d['address'] as String? ?? '',
      latitude: (d['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (d['longitude'] as num?)?.toDouble() ?? 0,
      cityId: d['cityId'] as String?,
      normalizedName: d['normalizedName'] as String?,
      aliases: _stringList(d['aliases']),
      keywords: _stringList(d['keywords']),
      searchCount: (d['searchCount'] as num?)?.toInt() ?? 0,
      verified: d['verified'] as bool? ?? false,
      source: 'firestore',
    );
  }

  // ── Sérialisation Firestore ─────────────────────────────────────────────
  Map<String, dynamic> toMap() => {
        'name': name,
        'nameSearch': nameNorm, // pour la recherche préfixe
        'category': category,
        'district': district,
        'address': address,
        'latitude': latitude,
        'longitude': longitude,
        if (cityId != null) 'cityId': cityId,
        'normalizedName': normalizedName,
        'aliases': aliases,
        'keywords': keywords,
        'searchCount': searchCount,
        'verified': verified,
        'source': source,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  // ── Pour créer un lieu depuis une source externe ────────────────────────
  factory LocalPlace.fromExternal({
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    String category = 'other',
    String district = 'Abengourou',
    String source = 'osm',
  }) =>
      LocalPlace(
        id: '',
        name: name,
        category: category,
        district: district,
        address: address,
        latitude: latitude,
        longitude: longitude,
        keywords: [LocalPlace.normalize(name)],
        source: source,
      );

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList(growable: false);
  }

  @override
  String toString() => 'LocalPlace($name @ $latitude,$longitude)';
}
