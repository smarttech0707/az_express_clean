import 'dart:io';
import 'dart:math' as math;

import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Les pages admin réelles exigent Firebase (flux Firestore) : on contrôle ici
// leur code source. Chaque page à onglets utilise la barre partagée AzTabBar,
// ses libellés correspondent, dans l'ordre, au contenu de son TabBarView, et
// son fond d'AppBar garantit un contraste lisible.

class _Page {
  const _Page(this.file, this.labels, this.children, this.bg);
  final String file;
  final List<String> labels;
  final List<String> children; // sous-chaînes, dans l'ordre du TabBarView
  final Color? bg; // null = fond du thème
}

const _blue = Color(0xFF1565C0);
const _pages = [
  _Page('admin_boulangerie_requests_page', ['En attente', 'Traitées'],
      ["statusFilter: 'pending'", 'statusFilter: null'], Color(0xFF5D4037)),
  _Page('admin_boutique_page', ['Produits', 'Commandes', 'Recharges'],
      ['_ProductsAdminTab()', '_OrdersAdminTab()', '_RechargesAdminTab()'],
      AppColors.primaryAction),
  _Page('admin_commissions_page', ['Statistiques', 'Historique'],
      ['_StatsTab(', '_HistoryTab()'], _blue),
  _Page('admin_ekbine_page', ['En attente', 'Approuvés', 'Rejetés', 'Commandes'],
      ["status: 'pending'", "status: 'approved'", "status: 'rejected'", '_OrdersTab('],
      Color(0xFF00695C)),
  _Page('admin_fleet_page', ['En attente', 'Approuvés', 'Rejetés'],
      ['"pending"', '"approved"', '"rejected"'], Color(0xFF6A1B9A)),
  _Page('admin_geo_stats_page',
      ['Zones actives', 'Routes fréquentes', 'Horaires de pointe', 'Évolution'],
      ['_buildZonesTab()', '_buildRoutesTab()', '_buildPeakHoursTab()', '_buildEvolutionTab()'],
      _blue),
  _Page('admin_pharmacie_requests_page', ['En attente', 'Traitées'],
      ["statusFilter: 'pending'", 'statusFilter: null'], Color(0xFFD32F2F)),
  _Page('admin_recharge_page',
      ['Recharge livreur', 'Retraits en attente', 'Traités', 'Échoués / Rejetés'],
      ['_RechargeDriverTab()', "'pending_manual'", "'processed'", "'failed'"],
      Color(0xFF2E7D32)),
  _Page('admin_restaurant_requests_page', ['En attente', 'Traitées'],
      ["statusFilter: 'pending'", 'statusFilter: null'], _blue),
  _Page('admin_seller_requests_page', ['En attente', 'Traitées'],
      ["statusFilter: 'pending'", 'statusFilter: null'], _blue),
  _Page('admin_service_requests_page', ['En attente', 'Traitées'],
      ["statusFilter: 'pending'", "statusFilter: 'done'"], _blue),
  _Page('admin_support_page', ['Tickets support', 'Signalements produits'],
      ['_TicketsTab()', '_ReportsTab()'], Color(0xFF00695C)),
  _Page('admin_zones_page', ['Tout', 'Villes', 'Quartiers', 'Villages', 'Secteurs'],
      ['_types[index]'], _blue),
  _Page('admin_vehicle_moderation_page',
      ['Annonces', 'Vendeurs', 'Pros/Magasins', 'Signalements'],
      ['_tabBody'], null),
];

double _contrast(Color a, Color b) {
  double lum(Color c) {
    double f(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  }

  final l1 = lum(a), l2 = lum(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

String _block(String s, String start) {
  final i = s.indexOf(start);
  expect(i, greaterThanOrEqualTo(0), reason: 'bloc $start introuvable');
  var depth = 0;
  for (var k = i + start.length - 1; k < s.length; k++) {
    if (s[k] == '(') depth++;
    if (s[k] == ')' && --depth == 0) return s.substring(i, k + 1);
  }
  fail('parenthèses non équilibrées après $start');
}

void main() {
  for (final p in _pages) {
    test('${p.file} : AzTabBar, libellés et contenu dans l\'ordre', () {
      final src =
          File('lib/screens/admin/${p.file}.dart').readAsStringSync();
      expect(src.contains(RegExp(r'(?<!Az)TabBar\(')), isFalse,
          reason: 'TabBar brut : utiliser AzTabBar');
      final bar = _block(src, 'AzTabBar(');
      if (p.file == 'admin_zones_page') {
        expect(src, contains("_tabs = ['Tout', 'Villes', 'Quartiers', 'Villages', 'Secteurs']"));
        expect(src, contains("_types = ['', 'ville', 'quartier', 'village', 'secteur']"));
        expect(bar, contains('labels: _tabs'));
      } else {
        final labels = RegExp('[\'"]([^\'"]+)[\'"]')
            .allMatches(bar.substring(bar.indexOf('labels:'), bar.indexOf(']', bar.indexOf('labels:'))))
            .map((m) => m.group(1))
            .toList();
        expect(labels, p.labels);
      }
      final view = _block(src, 'TabBarView(');
      var from = 0;
      for (final c in p.children) {
        final at = view.indexOf(c, from);
        expect(at, greaterThanOrEqualTo(from),
            reason: '« $c » absent ou hors ordre dans TabBarView');
        from = at;
      }
      if (p.file != 'admin_service_requests_page') {
        expect(bar, contains('controller:'));
      }
      if (p.bg != null) {
        expect(_contrast(Colors.white, p.bg!), greaterThanOrEqualTo(4.5),
            reason: 'fond de ${p.file}');
        expect(
            _contrast(
                Color.alphaBlend(const Color(0xFAFFFFFF), p.bg!), p.bg!),
            greaterThanOrEqualTo(4.5));
      }
    });
  }

  test('aucun TabBar brut dans l\'administration (hors composant partagé)', () {
    final raw = <String>[];
    for (final dir in ['lib/screens/admin', 'lib/event/screens']) {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.path.contains('event_provider_portal')) continue; // espace partenaire
        if (f.readAsStringSync().contains(RegExp(r'(?<!Az)TabBar\('))) {
          raw.add(f.path);
        }
      }
    }
    expect(raw, isEmpty);
  });

  test('la page Boutique n\'utilise plus le orange vif (2,9:1 avec du blanc)',
      () {
    final src = File('lib/screens/admin/admin_boutique_page.dart')
        .readAsStringSync();
    expect(src, contains('backgroundColor: AppColors.primaryAction'));
    expect(src, isNot(contains('backgroundColor: AppColors.primary,\n        foregroundColor: Colors.white,\n        centerTitle')));
  });
}
