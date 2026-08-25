import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

// ── Categories ─────────────────────────────────────────────────────────────────
const mpCategories = [
  {'id': 'phones', 'label': 'Téléphones', 'emoji': '📱'},
  {'id': 'tablets', 'label': 'Tablettes', 'emoji': '📟'},
  {'id': 'computers', 'label': 'Ordinateurs', 'emoji': '💻'},
  {'id': 'accessories', 'label': 'Accessoires', 'emoji': '🎧'},
];

// ── Brands by category ─────────────────────────────────────────────────────────
const phonesBrands = [
  'Apple',
  'Samsung',
  'Xiaomi',
  'Huawei',
  'Tecno',
  'Infinix',
  'Oppo',
  'Vivo',
  'Nokia',
  'Google Pixel',
  'Autre',
];
const tabletsBrands = [
  'Apple',
  'Samsung',
  'Lenovo',
  'Huawei',
  'Xiaomi',
  'Autre',
];
const computersBrands = [
  'HP',
  'Dell',
  'Lenovo',
  'Asus',
  'Acer',
  'MSI',
  'Apple',
  'Autre',
];
const accessoriesBrands = [
  'Apple',
  'Samsung',
  'Xiaomi',
  'Anker',
  'JBL',
  'Sony',
  'Logitech',
  'Baseus',
  'Autre',
];

List<String> brandsForCategory(String cat) {
  switch (cat) {
    case 'tablets':
      return tabletsBrands;
    case 'computers':
      return computersBrands;
    case 'accessories':
      return accessoriesBrands;
    default:
      return phonesBrands;
  }
}

// ── Condition ─────────────────────────────────────────────────────────────────
const mpConditions = [
  {'id': 'new', 'label': 'Neuf', 'color': 0xFF4CAF50},
  {'id': 'like_new', 'label': 'Quasi neuf', 'color': 0xFF2196F3},
  {'id': 'used', 'label': 'Occasion', 'color': 0xFFFF6D00},
];

String conditionLabel(String c) {
  switch (c) {
    case 'new':
      return 'Neuf';
    case 'like_new':
      return 'Quasi neuf';
    default:
      return 'Occasion';
  }
}

Color conditionColor(String c) {
  switch (c) {
    case 'new':
      return const Color(0xFF4CAF50);
    case 'like_new':
      return const Color(0xFF2196F3);
    default:
      return const Color(0xFFFF6D00);
  }
}

// ── Storage options ───────────────────────────────────────────────────────────
const storageOptions = [
  '16 Go',
  '32 Go',
  '64 Go',
  '128 Go',
  '256 Go',
  '512 Go',
  '1 To',
];

// ── RAM options ───────────────────────────────────────────────────────────────
const ramOptions = [
  '2 Go',
  '3 Go',
  '4 Go',
  '6 Go',
  '8 Go',
  '12 Go',
  '16 Go',
  '32 Go'
];

// ── Common colors ─────────────────────────────────────────────────────────────
const deviceColors = [
  'Noir',
  'Blanc',
  'Argent',
  'Or',
  'Bleu',
  'Rouge',
  'Vert',
  'Violet',
  'Rose',
  'Gris',
  'Autre',
];

// ── Villes ────────────────────────────────────────────────────────────────────
const mpCities = [
  'Abengourou',
  'Abidjan',
  'Bouaké',
  'Yamoussoukro',
  'San Pedro',
  'Daloa',
  'Korhogo',
  'Man',
  'Gagnoa',
  'Divo',
  'Autre',
];

// ── App theme (Master Prompt 120 — repointé vers la palette centrale,
// aucune identité de marque distincte pour le Marketplace) ─────────────────
const kMpOrange = AppColors.primary;
const kMpBg = AppColors.bg;
const kMpCard = AppColors.card;
const kMpText = AppColors.text;
const kMpMuted = AppColors.textMuted;
const kMpDivider = AppColors.divider;
