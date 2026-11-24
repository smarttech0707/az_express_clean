import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Projection GPS publique `driver_public` (SEC-01, Mission driver_public — phase S4).
///
/// Fonction PURE : construit uniquement la projection GPS (`lat`/`lng`/`heading`/`speed`/
/// `updatedAt`) à partir d'une [Position] déjà validée par l'appelant (même throttle que
/// l'écriture `livreurs` existante — aucun nouveau mécanisme introduit). Ne contient jamais
/// `wallet`/`phone`/`fcmToken`/`isSuspended`/etc. : strictement un sous-ensemble de la liste
/// blanche `driverPublicKeysValid()` (firestore.rules, phase S2).
///
/// Volontairement absents de cette phase (documentés, pas oubliés) :
/// - `name`/`photoUrl` : ni `DriverLocationService` ni l'écran de navigation ne les ont en
///   mémoire au moment de l'écriture GPS ; les lire exigerait un appel Firestore
///   supplémentaire rien que pour ces deux champs, ce que la mission interdit explicitement
///   (« ne pas créer une projection à partir d'un document complet `livreurs` »). Une
///   synchronisation dédiée (ex. au moment où `driver_profil.dart` modifie `photoUrl`) est
///   hors périmètre de cette phase, qui porte uniquement sur la double écriture GPS.
/// - `isOnline` : hors périmètre explicite de la mission S4 (qui ne liste que
///   name/photoUrl/lat/lng/heading/speed/updatedAt), à traiter dans une phase ultérieure.
@visibleForTesting
Map<String, Object?>? buildDriverPublicGpsProjection(Position pos) {
  final lat = pos.latitude;
  final lng = pos.longitude;
  if (!lat.isFinite || !lng.isFinite) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  // Placeholder posé à la création du livreur (driver_requests_page.dart) : jamais une
  // position réelle, ne doit jamais apparaître dans la projection publique.
  if (lat == 0 && lng == 0) return null;
  final data = <String, Object?>{
    'lat': lat,
    'lng': lng,
    'updatedAt': FieldValue.serverTimestamp(),
  };
  if (pos.heading.isFinite) data['heading'] = pos.heading;
  if (pos.speed.isFinite) data['speed'] = pos.speed;
  return data;
}

/// Point d'injection pour les tests (SEC-01, mission S4.1) — même pattern que
/// `positionStreamFactory`/`foregroundServiceStarter` dans `driver_location_service.dart` :
/// une variable de niveau module, `@visibleForTesting`, qui pointe par défaut vers la vraie
/// écriture Firestore. Un test peut la remplacer pour observer le payload exact transmis
/// (`docId`, `data`) ou simuler un échec, sans connexion Firebase réelle ; il doit la remettre
/// à [defaultDriverPublicWriter] après usage (voir `tearDown` dans le test associé). Ceci ne
/// change ni l'architecture ni le comportement par défaut : en production, ce champ n'est
/// jamais modifié et `writeDriverPublicGpsProjection` se comporte exactement comme avant.
@visibleForTesting
Future<void> Function(String docId, Map<String, Object?> data) driverPublicWriter =
    defaultDriverPublicWriter;

Future<void> defaultDriverPublicWriter(String docId, Map<String, Object?> data) =>
    FirebaseFirestore.instance
        .collection('driver_public')
        .doc(docId)
        .set(data, SetOptions(merge: true));

/// Écrit la projection dans `driver_public/{driverId}`, isolément de l'écriture `livreurs`
/// (déjà effectuée par l'appelant avant cet appel). Ne lève JAMAIS : une erreur ici (réseau,
/// permission, document non encore créé côté `livreurs`) ne doit ni masquer ni annuler
/// l'écriture principale, et aucune nouvelle tentative agressive n'est introduite — la
/// prochaine position (au même throttle qu'aujourd'hui) retentera naturellement.
Future<void> writeDriverPublicGpsProjection(String driverId, Position pos) async {
  final data = buildDriverPublicGpsProjection(pos);
  if (data == null) return; // position invalide ou placeholder : rien à écrire, pas une erreur
  try {
    await driverPublicWriter(driverId, data);
  } catch (e) {
    // Jamais de coordonnées ni d'identifiant dans le journal : uniquement le type d'erreur.
    debugPrint('[DriverPublic] projection GPS non écrite : ${e.runtimeType}');
  }
}
