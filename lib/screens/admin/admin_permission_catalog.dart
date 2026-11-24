import 'package:flutter/material.dart';

/// Catalogue public des 29 clés de permission proposées dans l'interface
/// de gestion des employés.
///
/// Recopie exacte de la liste privée `_kSections` de
/// `admin_sub_admins_page.dart` (non modifiée, zéro risque de régression
/// Android) — rendue publique et testable pour être réutilisée par le
/// Bureau Web (Phase 2 : gestion des employés). Volontairement **sans**
/// `auto_moto` : cette clé existe côté serveur (`PERMISSION_KEYS` dans
/// `functions/adminPermissions.js`, 30 clés) et dans `firestore.rules`
/// (`adminPermissionsKnown`), mais n'est proposée dans aucune interface —
/// le menu « Auto & Moto » reste réservé au super-admin. Le Web ne doit pas
/// l'exposer non plus, pour ne pas diverger du comportement mobile existant.
const adminPermissionCatalog = <(String key, String label, IconData icon)>[
  ('livreurs', 'Livreurs', Icons.delivery_dining_rounded),
  ('commandes', 'Commandes', Icons.receipt_long_rounded),
  ('gains', 'Gains', Icons.bar_chart_rounded),
  ('classement', 'Classement', Icons.emoji_events_rounded),
  ('carte', 'Carte live', Icons.map_rounded),
  ('demandes', 'Demandes livreurs', Icons.person_add_rounded),
  ('restaurants', 'Restaurants', Icons.restaurant_rounded),
  ('demandes_resto', 'Dem. Restos', Icons.store_mall_directory_rounded),
  ('demandes_vendeurs', 'Dem. Vendeurs', Icons.storefront_rounded),
  ('demandes_boulangeries', 'Dem. Boulangeries', Icons.bakery_dining_rounded),
  ('demandes_pharmacies', 'Dem. Pharmacies', Icons.local_pharmacy_rounded),
  ('pharmacies', 'Pharmacies', Icons.local_pharmacy_rounded),
  ('boutique', 'Boutique', Icons.storefront_rounded),
  ('recharges', 'Recharges', Icons.account_balance_wallet_rounded),
  ('flottes', 'Flottes', Icons.motorcycle_rounded),
  ('locations', 'Locations', Icons.home_rounded),
  ('residences', 'Résidences', Icons.apartment_rounded),
  ('services', 'Services', Icons.construction_rounded),
  ('eventiel', 'Événementiel', Icons.celebration_rounded),
  ('tricycle', 'Tricycle & Taxi', Icons.local_taxi_rounded),
  ('sos', 'Alertes SOS', Icons.sos_rounded),
  ('anti_fraude', 'Anti-fraude', Icons.gpp_bad_rounded),
  ('cash_marchand', 'Cash à régler', Icons.payments_rounded),
  ('support', 'Support & Signalements', Icons.support_agent_rounded),
  ('ai_dashboard', 'Tableau de bord IA', Icons.smart_toy_rounded),
  ('boulangeries', 'Boulangeries', Icons.bakery_dining_rounded),
  ('zones', 'Zones Géo', Icons.add_location_alt_rounded),
  ('ekbine', 'Agents E-Kbine', Icons.sim_card_rounded),
  ('purger', 'Purger', Icons.delete_sweep_rounded),
];

/// Libellé d'une clé de permission, ou la clé elle-même si inconnue (jamais
/// d'exception sur une clé obsolète déjà présente sur un vieux compte).
String adminPermissionLabel(String key) {
  for (final entry in adminPermissionCatalog) {
    if (entry.$1 == key) return entry.$2;
  }
  return key;
}

/// Une catégorie présentative pour regrouper les 29 permissions du
/// catalogue. Purement présentatif : aucune nouvelle clé, aucun changement
/// des identifiants existants, aucune catégorie ne modifie la sécurité —
/// seulement l'organisation visuelle du Bureau Web (amélioration du
/// formulaire « Nouvel employé »).
class AdminPermissionCategory {
  final String label;
  final IconData icon;
  final List<String> keys;
  const AdminPermissionCategory(
      {required this.label, required this.icon, required this.keys});
}

/// Partition exacte des 29 clés de `adminPermissionCatalog` en 9
/// catégories logiques — chaque clé apparaît dans exactement une catégorie
/// (vérifié par un test de parité).
const adminPermissionCategories = <AdminPermissionCategory>[
  AdminPermissionCategory(
    label: 'Livraisons et livreurs',
    icon: Icons.delivery_dining_rounded,
    keys: ['livreurs', 'flottes', 'tricycle', 'demandes', 'classement'],
  ),
  AdminPermissionCategory(
    label: 'Commandes',
    icon: Icons.receipt_long_rounded,
    keys: ['commandes', 'carte'],
  ),
  AdminPermissionCategory(
    label: 'Finances et gains',
    icon: Icons.account_balance_wallet_rounded,
    keys: ['gains', 'recharges', 'cash_marchand'],
  ),
  AdminPermissionCategory(
    label: 'Partenaires et commerces',
    icon: Icons.storefront_rounded,
    keys: [
      'restaurants',
      'demandes_resto',
      'demandes_vendeurs',
      'demandes_boulangeries',
      'demandes_pharmacies',
      'pharmacies',
      'boutique',
      'boulangeries',
      'locations',
      'residences',
    ],
  ),
  AdminPermissionCategory(
    label: 'Services et demandes',
    icon: Icons.construction_rounded,
    keys: ['services', 'eventiel'],
  ),
  AdminPermissionCategory(
    label: 'Gestion géographique',
    icon: Icons.add_location_alt_rounded,
    keys: ['zones'],
  ),
  AdminPermissionCategory(
    label: 'E-Kbine',
    icon: Icons.sim_card_rounded,
    keys: ['ekbine'],
  ),
  AdminPermissionCategory(
    label: 'Sécurité et support',
    icon: Icons.support_agent_rounded,
    keys: ['sos', 'anti_fraude', 'support'],
  ),
  AdminPermissionCategory(
    label: 'Outils et statistiques',
    icon: Icons.smart_toy_rounded,
    keys: ['ai_dashboard', 'purger'],
  ),
];

/// Nouvel ensemble après avoir basculé une seule permission — fonction pure,
/// testable sans monter de widget.
Set<String> togglePermission(Set<String> current, String key) {
  final next = Set<String>.from(current);
  if (next.contains(key)) {
    next.remove(key);
  } else {
    next.add(key);
  }
  return next;
}

/// Toutes les permissions du catalogue (« Tout sélectionner »).
Set<String> selectAllPermissions() =>
    {for (final e in adminPermissionCatalog) e.$1};

/// Aucune permission (« Tout désélectionner »).
Set<String> deselectAllPermissions() => const {};

/// Bascule une catégorie entière : si elle est déjà entièrement
/// sélectionnée, la désélectionne ; sinon, la sélectionne entièrement
/// (jamais un état partiel après l'action, pour rester prévisible).
Set<String> toggleCategorySelection(
    Set<String> current, AdminPermissionCategory category) {
  final allSelected = category.keys.every(current.contains);
  final next = Set<String>.from(current);
  if (allSelected) {
    next.removeAll(category.keys);
  } else {
    next.addAll(category.keys);
  }
  return next;
}

/// Résumé lisible des permissions sélectionnées, regroupé par catégorie
/// (ex. "Livraisons et livreurs (3), Finances et gains (2)"), pour
/// vérification avant création — fonction pure, testable.
String summarizeSelectedPermissions(Set<String> selected) {
  if (selected.isEmpty) return 'Aucune permission sélectionnée';
  final parts = <String>[];
  for (final cat in adminPermissionCategories) {
    final count = cat.keys.where(selected.contains).length;
    if (count > 0) parts.add('${cat.label} ($count)');
  }
  return parts.join(', ');
}
