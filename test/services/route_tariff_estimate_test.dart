// Lot 1.1 — sécurisation du calcul des tarifs face aux itinéraires estimés.
//
// `GoogleRoutesService._fallback()` renvoie désormais systématiquement
// `isEstimate: true` (Lot 1). Avant ce lot, `create_order.dart` et
// `livraison_screen.dart` traitaient cette ligne droite exactement comme un
// itinéraire routier réel pour calculer la distance facturée : aucun tarif
// n'était modifié par erreur (même barème), mais la distance utilisée en
// entrée de `TarifService.compute` pouvait être un vol d'oiseau présenté
// comme une distance routière confirmée, sans aucun avertissement visible.
//
// `RouteModel.resolveTariffDistance` et `RouteModel.shouldShowEstimateNotice`
// sont la correction : une seule règle de vérité, partagée entre les deux
// écrans (et testable sans Firebase/GPS, contrairement aux State privés).
import 'package:az_express/models/route_model.dart';
import 'package:az_express/services/delivery_service.dart';
import 'package:az_express/services/google_routes_service.dart';
import 'package:az_express/services/maps_proxy_client.dart';
import 'package:az_express/services/tarif_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

RouteModel _real({required double km, required int etaMin}) => RouteModel(
      points: const [LatLng(6.7273, -3.4961), LatLng(6.74, -3.48)],
      distanceKm: km,
      etaMinutes: etaMin,
      distanceText: RouteModel.formatDistance(km),
      etaText: RouteModel.formatEta(etaMin),
      estimatedPrice: RouteModel.estimatePrice(km),
    );

RouteModel _estimate({required double km}) => RouteModel(
      points: const [LatLng(6.7273, -3.4961), LatLng(6.74, -3.48)],
      distanceKm: km,
      etaMinutes: RouteModel.estimateEta(km),
      distanceText: RouteModel.formatDistance(km),
      etaText: RouteModel.formatEta(RouteModel.estimateEta(km)),
      estimatedPrice: RouteModel.estimatePrice(km),
      isEstimate: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RouteModel.resolveTariffDistance', () {
    test('itinéraire réel : sa distance est utilisée, isRealRoute vrai', () {
      final r = RouteModel.resolveTariffDistance(
        route: _real(km: 4.2, etaMin: 12),
        haversineFallbackKm: 3.0,
      );
      expect(r.distanceKm, 4.2);
      expect(r.isRealRoute, isTrue);
    });

    test(
        'itinéraire estimé : REFUSÉ comme distance routière réelle, '
        'retombe sur le vol d\'oiseau fourni', () {
      final r = RouteModel.resolveTariffDistance(
        route: _estimate(km: 9.9), // ligne droite très différente du réel
        haversineFallbackKm: 3.0,
      );
      expect(r.distanceKm, 3.0, reason: 'jamais la distance de l\'estimation');
      expect(r.isRealRoute, isFalse);
    });

    test('absence d\'itinéraire (RouteModel.empty) : vol d\'oiseau, non réel',
        () {
      final r = RouteModel.resolveTariffDistance(
        route: RouteModel.empty(),
        haversineFallbackKm: 5.5,
      );
      expect(r.distanceKm, 5.5);
      expect(r.isRealRoute, isFalse);
    });

    test('itinéraire réel à distance nulle (même point) : jamais retenu', () {
      final r = RouteModel.resolveTariffDistance(
        route: _real(km: 0, etaMin: 0),
        haversineFallbackKm: 0,
      );
      expect(r.isRealRoute, isFalse);
    });
  });

  group('Calcul du prix — itinéraire réel vs estimation (TarifService)', () {
    // Heure fixe, de jour, bien avant le couvre-feu (21h) : le prix ne
    // dépend ici que de la distance, jamais de l'heure du test.
    final day = DateTime(2026, 1, 15, 14, 0);
    const destLat = 6.90, destLng = -3.55; // hors zone centrale (~20 km)

    test('prix calculé avec la distance de l\'itinéraire réel', () {
      final resolved = RouteModel.resolveTariffDistance(
        route: _real(km: 20.0, etaMin: 40),
        haversineFallbackKm: 18.0,
      );
      // Comme create_order.dart : `resolved.distanceKm` est toujours transmis
      // (c'est déjà soit la distance réelle, soit le repli vol d'oiseau).
      final tarif = TarifService.compute(
        clientLat: destLat,
        clientLng: destLng,
        routeDistanceKm: resolved.distanceKm,
        time: day,
      );
      // Le prix hors zone dépend de la distance réelle fournie (20.0), pas
      // du vol d'oiseau (18.0) : si le moteur varie le prix avec la
      // distance, les deux doivent différer ici.
      final tarifHaversine = TarifService.compute(
        clientLat: destLat,
        clientLng: destLng,
        routeDistanceKm: 18.0,
        time: day,
      );
      expect(tarif.canOrder, isTrue);
      expect(tarif.standardPrice, isNot(0));
      expect(tarif.standardPrice, isNot(tarifHaversine.standardPrice),
          reason: 'la distance réelle (20 km) doit bien être celle utilisée, '
              'pas le vol d\'oiseau (18 km)');
    });

    test(
        'refus de présenter un calcul basé sur une estimation comme réel : '
        'le prix retombe sur le vol d\'oiseau, jamais sur la ligne droite',
        () {
      final resolved = RouteModel.resolveTariffDistance(
        route: _estimate(km: 35.0), // ligne droite aberrante
        haversineFallbackKm: 18.0,
      );
      final tarif = TarifService.compute(
        clientLat: destLat,
        clientLng: destLng,
        routeDistanceKm: resolved.distanceKm,
        time: day,
      );
      final tarifHaversine = TarifService.compute(
        clientLat: destLat,
        clientLng: destLng,
        routeDistanceKm: 18.0,
        time: day,
      );
      expect(resolved.isRealRoute, isFalse);
      expect(tarif.standardPrice, tarifHaversine.standardPrice,
          reason: 'la distance de l\'estimation (35 km) ne doit jamais '
              'influencer le prix');
    });
  });

  group('PriceBreakdown — drapeau d\'estimation (create_order.dart)', () {
    test('false par défaut, ne change aucun autre champ', () {
      const b = PriceBreakdown(
        total: 500,
        distanceKm: 2.0,
        etaMinutes: 10,
        isNight: false,
        detail: 'Tarif jour — zone centrale',
      );
      expect(b.isEstimate, isFalse);
      expect(b.total, 500);
    });

    test('peut être marqué vrai sans toucher au total ni au détail', () {
      const b = PriceBreakdown(
        total: 500,
        distanceKm: 2.0,
        etaMinutes: 10,
        isNight: false,
        detail: 'Tarif jour — zone centrale',
        isEstimate: true,
      );
      expect(b.isEstimate, isTrue);
      expect(b.total, 500, reason: 'aucun tarif modifié par le drapeau');
      expect(b.detail, 'Tarif jour — zone centrale');
    });
  });

  group('RouteModel.shouldShowEstimateNotice (bandeau client + livreur)', () {
    test('aucun tronçon : pas de bandeau', () {
      expect(
        RouteModel.shouldShowEstimateNotice(
            [RouteModel.empty(), RouteModel.empty()]),
        isFalse,
      );
    });

    test('un seul tronçon réel non vide : pas de bandeau', () {
      expect(
        RouteModel.shouldShowEstimateNotice(
            [_real(km: 3, etaMin: 8), RouteModel.empty()]),
        isFalse,
      );
    });

    test('un tronçon estimé parmi plusieurs : bandeau affiché', () {
      expect(
        RouteModel.shouldShowEstimateNotice(
            [_real(km: 3, etaMin: 8), _estimate(km: 7)]),
        isTrue,
      );
    });

    test('tronçon estimé mais vide (edge case défensif) : pas de bandeau',
        () {
      // Un RouteModel.empty() a isEstimate=false par défaut ; même si un
      // appelant le marquait isEstimate, un tronçon vide (non affiché sur
      // la carte) ne doit pas déclencher le bandeau.
      final emptyMarked = RouteModel.empty().copyWith(isEstimate: true);
      expect(emptyMarked.isEmpty, isTrue);
      expect(
        RouteModel.shouldShowEstimateNotice([emptyMarked]),
        isFalse,
      );
    });
  });

  group('Reprise de l\'itinéraire réel après retour du réseau', () {
    setUp(() {
      GoogleRoutesService.debugResetCache();
      MapsProxyClient.debugCall = null;
    });
    tearDown(() {
      GoogleRoutesService.debugResetCache();
      MapsProxyClient.debugCall = null;
    });

    const origin = LatLng(6.7273, -3.4961);
    const destination = LatLng(6.80, -3.40);
    const polyline = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';

    test(
        'proxy indisponible puis de nouveau joignable : le second appel '
        'retrouve un itinéraire réel, non estimé, et le met en cache', () async {
      var up = false;
      MapsProxyClient.debugCall = (_, __) async {
        if (!up) return null; // simule une coupure réseau
        return {
          'encodedPolyline': polyline,
          'distanceMeters': 5000,
          'durationSeconds': 600,
          'isEstimate': false,
        };
      };

      final duringOutage = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      expect(duringOutage.isEstimate, isTrue,
          reason: 'hors ligne : ligne droite signalée comme estimation');

      up = true;
      final afterRecovery = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      expect(afterRecovery.isEstimate, isFalse,
          reason: 'retour réseau : itinéraire réel repris immédiatement, '
              'la précédente estimation ne devait pas rester en cache');
      expect(afterRecovery.distanceKm, closeTo(5.0, 1e-9));

      // Et ce résultat réel est bien mis en cache (aucun nouvel appel réseau).
      var calls = 0;
      MapsProxyClient.debugCall = (_, __) async {
        calls++;
        return null;
      };
      final cached = await GoogleRoutesService.getRouteModel(
          origin: origin, destination: destination);
      expect(calls, 0, reason: 'l\'itinéraire réel reste en cache 2 minutes');
      expect(cached.isEstimate, isFalse);
    });
  });
}
