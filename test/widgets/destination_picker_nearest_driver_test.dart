import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

// SEC-01 S6.3 : migration de `destination_picker.dart::_loadNearestDriver`
// depuis `livreurs` vers `driver_public` (filtre `isOnline`, champs `lat`,
// `lng`, `name`, tous dans la liste blanche `driver_public`). Un test widget
// complet pilotant une vraie requête Firestore `.where().limit().get()`
// n'est pas réalisable ici : aucun paquet de simulation Firestore dans le
// dépôt (cf. test/screens/driver/driver_accept_selfie_test.dart) et
// l'ajout d'une dépendance pour y remédier est explicitement interdit dans
// cette phase. Ce test isole donc l'algorithme de sélection du livreur le
// plus proche tel qu'implémenté dans le widget, sur des documents simulés
// en mémoire (pas de Firestore), pour couvrir : champ absent/placeholder
// `(0,0)` ignoré, nom de repli, et sélection par distance minimale.

class _Doc {
  const _Doc(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

class _NearestDriver {
  const _NearestDriver(this.position, this.name);
  final ({double lat, double lng}) position;
  final String name;
}

/// Reproduit exactement la logique de `_loadNearestDriver` (sans Firestore) :
/// ignore les documents sans position valide, choisit le plus proche du
/// client, retombe sur "Livreur" si `name` est absent.
_NearestDriver? nearestDriver(
  List<_Doc> docs, {
  required double clientLat,
  required double clientLng,
}) {
  double minDist = double.infinity;
  _Doc? nearest;
  for (final doc in docs) {
    final d = doc.data;
    final lat = (d['lat'] as num?)?.toDouble() ?? 0;
    final lng = (d['lng'] as num?)?.toDouble() ?? 0;
    if (lat == 0 || lng == 0) continue;
    final dist = Geolocator.distanceBetween(clientLat, clientLng, lat, lng);
    if (dist < minDist) {
      minDist = dist;
      nearest = doc;
    }
  }
  if (nearest == null) return null;
  final d = nearest.data;
  return _NearestDriver(
    (lat: (d['lat'] as num).toDouble(), lng: (d['lng'] as num).toDouble()),
    d['name'] as String? ?? 'Livreur',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DestinationPicker — sélection du livreur le plus proche (driver_public)', () {
    const client = (lat: 6.73, lng: -3.49);

    test('aucun document en ligne → aucun livreur', () {
      expect(nearestDriver(const [], clientLat: client.lat, clientLng: client.lng), isNull);
    });

    test('document avec placeholder (0,0) ignoré', () {
      final result = nearestDriver(
        [const _Doc('d1', {'lat': 0, 'lng': 0, 'name': 'Koffi'})],
        clientLat: client.lat,
        clientLng: client.lng,
      );
      expect(result, isNull);
    });

    test('nom absent → repli "Livreur"', () {
      final result = nearestDriver(
        [const _Doc('d1', {'lat': 6.731, 'lng': -3.491})],
        clientLat: client.lat,
        clientLng: client.lng,
      );
      expect(result!.name, 'Livreur');
    });

    test('plusieurs livreurs → le plus proche est choisi', () {
      final result = nearestDriver(
        [
          const _Doc('loin', {'lat': 6.80, 'lng': -3.60, 'name': 'Loin'}),
          const _Doc('proche', {'lat': 6.731, 'lng': -3.491, 'name': 'Proche'}),
        ],
        clientLat: client.lat,
        clientLng: client.lng,
      );
      expect(result!.name, 'Proche');
    });
  });
}
