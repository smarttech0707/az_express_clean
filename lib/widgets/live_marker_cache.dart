import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

enum LiveMarkerChangeType { added, modified, removed }

class LiveMarkerChange {
  const LiveMarkerChange(this.id, this.type, {this.marker});
  final String id;
  final LiveMarkerChangeType type;
  final Marker? marker;
}

Map<String, Marker> applyLiveMarkerChanges(
  Map<String, Marker> current,
  Iterable<LiveMarkerChange> changes,
) {
  final next = Map<String, Marker>.from(current);
  for (final change in changes) {
    if (change.type == LiveMarkerChangeType.removed || change.marker == null) {
      next.remove(change.id);
    } else {
      next[change.id] = change.marker!;
    }
  }
  return next;
}

// ─────────────────────────────────────────────────────────────────────────────
// Flux « livreurs en ligne » — couche d'injection minimale pour les tests.
//
// La requête Firestore de production reste STRICTEMENT identique :
//   collection('livreurs').where('isOnline', isEqualTo: true).snapshots()
// On ajoute seulement un `.map()` qui adapte `QuerySnapshot` en un type valeur
// simple (`LiveDriverSnapshot`), afin qu'un test puisse fournir un faux flux
// sans Firebase. Aucun nouveau service, aucune nouvelle architecture globale.
// ─────────────────────────────────────────────────────────────────────────────

/// Un document livreur tel que consommé par les écrans de carte temps réel.
class LiveDriverDoc {
  const LiveDriverDoc(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

/// Un changement incrémental (added/modified/removed) dans le flux livreurs —
/// équivalent de `DocumentChange` réduit à ce que les écrans utilisent.
class LiveDriverDocChange {
  const LiveDriverDocChange(this.type, this.doc);
  final LiveMarkerChangeType type;
  final LiveDriverDoc doc;
}

/// Une émission du flux : l'ensemble courant des livreurs + les changements
/// depuis l'émission précédente (miroir de `QuerySnapshot.docs` / `.docChanges`).
class LiveDriverSnapshot {
  const LiveDriverSnapshot({
    required this.docs,
    required this.docChanges,
  });
  final List<LiveDriverDoc> docs;
  final List<LiveDriverDocChange> docChanges;
}

/// Point d'injection : une fabrique de flux. La valeur par défaut branche la
/// vraie requête Firestore (voir [onlineDriversFeed]).
typedef LiveDriverFeed = Stream<LiveDriverSnapshot> Function();

LiveMarkerChangeType _mapDocChangeType(DocumentChangeType type) {
  switch (type) {
    case DocumentChangeType.added:
      return LiveMarkerChangeType.added;
    case DocumentChangeType.modified:
      return LiveMarkerChangeType.modified;
    case DocumentChangeType.removed:
      return LiveMarkerChangeType.removed;
  }
}

/// Adapte un `QuerySnapshot` Firestore en [LiveDriverSnapshot].
LiveDriverSnapshot liveDriverSnapshotFromQuery(
  QuerySnapshot<Map<String, dynamic>> snap,
) {
  return LiveDriverSnapshot(
    docs: [
      for (final d in snap.docs) LiveDriverDoc(d.id, d.data()),
    ],
    docChanges: [
      for (final c in snap.docChanges)
        LiveDriverDocChange(
          _mapDocChangeType(c.type),
          LiveDriverDoc(c.doc.id, c.doc.data() ?? const <String, dynamic>{}),
        ),
    ],
  );
}

/// Flux de production, inchangé fonctionnellement : `livreurs` en ligne en
/// temps réel, adapté à [LiveDriverSnapshot].
Stream<LiveDriverSnapshot> onlineDriversFeed() {
  return FirebaseFirestore.instance
      .collection('livreurs')
      .where('isOnline', isEqualTo: true)
      .snapshots()
      .map(liveDriverSnapshotFromQuery);
}
