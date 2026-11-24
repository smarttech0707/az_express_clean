import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../models/real_estate_listing.dart';
import '../models/real_estate_agent.dart';
import '../models/real_estate_private_location.dart';
import '../models/real_estate_property_type.dart';
import '../models/real_estate_visit_request.dart';
import 'map_navigation_service.dart';

/// Service statique pour le module Immobilier — mêmes conventions que
/// lib/marketplace/services/mp_service.dart (recherche/filtrage côté client
/// car Firestore ne fait pas de recherche plein texte) et lib/ekbine pour
/// l'appel aux Cloud Functions.
class RealEstateService {
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;
  static final _listings = _db.collection('real_estate_listings');
  static final _fn = FirebaseFunctions.instanceFor(region: 'europe-west1');

  // ── Annonces ─────────────────────────────────────────────────────────────

  static Stream<List<RealEstateListing>> streamActive({
    int limit = 40,
    String? propertyType,
    String? priceType,
    bool? furnished,
  }) {
    Query<Map<String, dynamic>> query =
        _listings.where('status', isEqualTo: 'active');
    if (propertyType != null) {
      query = query.where('propertyType', isEqualTo: propertyType);
    }
    if (priceType != null) {
      query = query.where('priceType', isEqualTo: priceType);
    }
    if (furnished != null) {
      query = query.where('furnished', isEqualTo: furnished);
    }
    return query
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(RealEstateListing.fromDoc).toList());
  }

  static Stream<List<RealEstateListing>> streamByAgent(String agentId) =>
      _listings
          .where('agentId', isEqualTo: agentId)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((s) => s.docs.map(RealEstateListing.fromDoc).toList());

  /// Taille de page Firestore par requête — inchangée (déjà la valeur en
  /// place avant la Mission 6 de "Immobilier V6.1").
  static const int _searchPageSize = 80;

  /// Master Prompt "Immobilier V6.1" — Mission 6 : nombre de correspondances
  /// jugé suffisant pour une liste mobile (même ordre de grandeur que
  /// `streamActive(limit: 40)` déjà utilisé ailleurs dans ce fichier).
  static const int _searchTargetMatches = 60;

  /// Plafond de pages absolu — borne le coût Firestore même si les filtres
  /// ne trouvent jamais assez de résultats (400 annonces actives les plus
  /// récentes scannées au maximum). Documenté explicitement plutôt que
  /// laissé illimité : au-delà de ce volume, seule une vraie migration vers
  /// des filtres Firestore indexables (voir commentaire de [search])
  /// garantirait l'exhaustivité — hors périmètre de ce correctif ciblé.
  static const int _searchMaxPages = 5;

  /// Master Prompt "Immobilier V6" — Mission 4 : filtres étendus, tous
  /// appliqués côté client après une requête Firestore de base (même
  /// discipline que l'existant : jamais de nouvel index composite requis).
  ///
  /// ⚠️ Master Prompt "Immobilier V6.1" — Mission 6 : risque confirmé et
  /// corrigé. Avant cette passe, une seule page de 80 documents était lue
  /// (triés par date de création) puis filtrée en mémoire — une annonce
  /// correspondant aux critères mais qui ne faisait pas partie des 80 plus
  /// récentes (ex. la 90ᵉ) n'était jamais vue, sans aucune indication à
  /// l'utilisateur qu'un résultat existait ailleurs. Corrigé par une lecture
  /// **progressive multi-pages** (curseur `startAfterDocument`) : tant que
  /// le nombre de correspondances est insuffisant ET qu'il reste des
  /// documents à lire ET que le plafond de pages n'est pas atteint, une page
  /// supplémentaire est chargée. Aucun nouvel index composite requis (chaque
  /// page utilise exactement la même requête de base qu'avant). Limite
  /// honnête : reste borné à [_searchMaxPages] × [_searchPageSize] documents
  /// scannés au maximum — pas une garantie d'exhaustivité à volume illimité,
  /// mais un risque très concret réduit à un cas extrême (des centaines
  /// d'annonces actives non correspondantes avant la bonne) plutôt que
  /// systématique (dès la 81ᵉ annonce, quel que soit le filtre).
  static Future<List<RealEstateListing>> search({
    String? query,
    String? propertyType,
    String? city,
    String? quartier,
    String? priceType,
    bool? furnished,
    int? minPrice,
    int? maxPrice,
    double? minSurface,
    double? maxSurface,
    int? minBedrooms,
    bool? hasPool,
    bool? hasGarage,
    bool? hasParking,
    bool? hasInternet,
    bool? availableOnly,
    bool landOnly = false,
    bool commercialOnly = false,
    bool furnishedResidenceOnly = false,
    // Distance GPS — jamais appliquée sur une coordonnée privée non
    // autorisée : seule `publicLatitude`/`publicLongitude` est utilisée,
    // déjà la seule position légitimement publique (voir
    // `RealEstateDisplayLocation`, jamais dupliqué ici).
    double? fromLatitude,
    double? fromLongitude,
    double? maxDistanceKm,
  }) async {
    bool matchesFilters(RealEstateListing l) {
      if (query != null && query.trim().isNotEmpty) {
        final needle = query.toLowerCase().trim();
        if (!l.title.toLowerCase().contains(needle) &&
            !l.description.toLowerCase().contains(needle)) {
          return false;
        }
      }
      if (city != null && city.isNotEmpty) {
        if (!l.city.toLowerCase().contains(city.toLowerCase())) return false;
      }
      if (quartier != null && quartier.isNotEmpty) {
        if (!(l.quartier ?? '')
            .toLowerCase()
            .contains(quartier.toLowerCase())) {
          return false;
        }
      }
      if (priceType != null &&
          priceType.isNotEmpty &&
          l.priceType != priceType) {
        return false;
      }
      if (furnished != null && l.furnished != furnished) return false;
      if (minPrice != null && l.price < minPrice) return false;
      if (maxPrice != null && l.price > maxPrice) return false;
      final surfaceForRange = l.surface ?? l.surfaceTerrain ?? 0;
      if (minSurface != null && surfaceForRange < minSurface) return false;
      if (maxSurface != null && surfaceForRange > maxSurface) return false;
      if (minBedrooms != null && (l.bedrooms ?? 0) < minBedrooms) return false;
      if (hasPool == true && !l.hasPool) return false;
      if (hasGarage == true && !l.hasGarage) return false;
      if (hasParking == true && !l.hasParking) return false;
      if (hasInternet == true && !l.hasInternet) return false;
      if (availableOnly == true && !l.isAvailable) return false;
      if (landOnly && !RealEstatePropertyType.isLand(l.propertyType)) {
        return false;
      }
      if (commercialOnly &&
          !RealEstatePropertyType.isCommercialType(l.propertyType)) {
        return false;
      }
      if (furnishedResidenceOnly &&
          !RealEstatePropertyType.isFurnishedResidenceType(l.propertyType)) {
        return false;
      }
      if (fromLatitude != null &&
          fromLongitude != null &&
          maxDistanceKm != null) {
        if (!l.hasPublicLocation) return false;
        final meters = MapNavigationService.distanceMeters(
          fromLat: fromLatitude,
          fromLng: fromLongitude,
          toLat: l.publicLatitude!,
          toLng: l.publicLongitude!,
        );
        if (meters > maxDistanceKm * 1000) return false;
      }
      return true;
    }

    Query<Map<String, dynamic>> baseQuery =
        _listings.where('status', isEqualTo: 'active');
    if (propertyType != null && propertyType.isNotEmpty) {
      baseQuery = baseQuery.where('propertyType', isEqualTo: propertyType);
    }
    baseQuery = baseQuery.orderBy('createdAt', descending: true);

    final results = <RealEstateListing>[];
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    for (var page = 0; page < _searchMaxPages; page++) {
      var pageQuery = baseQuery.limit(_searchPageSize);
      if (cursor != null) pageQuery = pageQuery.startAfterDocument(cursor);
      final snap = await pageQuery.get();
      if (snap.docs.isEmpty) break;
      cursor = snap.docs.last;
      results.addAll(
          snap.docs.map(RealEstateListing.fromDoc).where(matchesFilters));
      final reachedEndOfCollection = snap.docs.length < _searchPageSize;
      if (results.length >= _searchTargetMatches || reachedEndOfCollection) {
        break;
      }
    }
    return results;
  }

  static Future<String> addListing(Map<String, dynamic> data) async {
    final ref = await _listings.add(data);
    return ref.id;
  }

  static Future<void> updateListing(String id, Map<String, dynamic> data) =>
      _listings.doc(id).update(data);

  static Future<void> softDelete(String id) =>
      _listings.doc(id).update({'status': 'hidden'});

  static Future<void> reactivate(String id) =>
      _listings.doc(id).update({'status': 'active'});

  static Future<void> incrementViews(String id) =>
      _listings.doc(id).update({'views': FieldValue.increment(1)});

  // ── Localisation (GPS privé/confidentialité réelle V2) ──────────────────
  //
  // Écriture EXCLUSIVEMENT via cette Cloud Function — jamais un
  // `_listings.doc(id).update({...lat/lng...})` direct, bloqué de toute
  // façon côté Rules (`noDirectLocationFieldsOnCreate`/`locationFieldsUnchanged`).

  /// Appelle `upsertRealEstateLocation` — l'annonce doit déjà exister
  /// (créée via [addListing]) avant ce second appel (flux en deux étapes,
  /// voir Mission 13). [locationPrivacy] doit valoir 'exact', 'approximate'
  /// ou 'hidden'.
  static Future<void> upsertLocation({
    required String listingId,
    required double latitude,
    required double longitude,
    required String locationPrivacy,
    String? address,
    String? city,
    String? quartier,
    String? locationLabel,
  }) async {
    await _fn.httpsCallable('upsertRealEstateLocation').call({
      'listingId': listingId,
      'latitude': latitude,
      'longitude': longitude,
      'locationPrivacy': locationPrivacy,
      if (address != null) 'address': address,
      if (city != null) 'city': city,
      if (quartier != null) 'quartier': quartier,
      if (locationLabel != null) 'locationLabel': locationLabel,
    });
  }

  /// Lecture directe Firestore (pas de Cloud Function nécessaire en
  /// lecture) — les Rules de `real_estate_private_locations` sont la seule
  /// et unique barrière : propriétaire/agent, admin, ou client avec un
  /// accès accordé après visite confirmée. Retourne `null` si le document
  /// n'existe pas encore (localisation jamais renseignée) ou si les Rules
  /// refusent la lecture (utilisateur non autorisé).
  static Future<RealEstatePrivateLocation?> getPrivateLocation(
      String listingId) async {
    try {
      final doc = await _db
          .collection('real_estate_private_locations')
          .doc(listingId)
          .get();
      return doc.exists ? RealEstatePrivateLocation.fromDoc(doc) : null;
    } catch (_) {
      return null;
    }
  }

  /// Chargement de la position privée UNIQUEMENT après validation réelle de
  /// l'accès (Mission 3 du chantier "Activation UI carte/itinéraire") — à
  /// n'appeler que pour une annonce `approximate`/`hidden` et un utilisateur
  /// authentifié, jamais systématiquement pour tout client (voir l'appelant
  /// dans `listing_detail_screen.dart`).
  ///
  /// Revérifie `isActive`/`expiresAt` côté client avant même de tenter la
  /// lecture du document privé — une vérification redondante avec les Rules
  /// (qui restent la seule vraie barrière, voir `firestore.rules`), mais qui
  /// permet de distinguer proprement "pas d'accès" de "accès expiré" sans
  /// jamais faire confiance à cette distinction pour la sécurité elle-même.
  /// Ne journalise jamais aucune coordonnée ni le contenu de l'accès.
  static Future<RealEstatePrivateLocation?> resolveAuthorizedPrivateLocation({
    required String listingId,
    required String clientId,
  }) async {
    try {
      final accessDoc = await _db
          .collection('real_estate_location_access')
          .doc('${listingId}_$clientId')
          .get();
      if (!accessDoc.exists) return null;
      final access = accessDoc.data()!;
      if (access['isActive'] != true) return null;
      final expiresAt = access['expiresAt'];
      if (expiresAt is Timestamp &&
          expiresAt.toDate().isBefore(DateTime.now())) {
        return null;
      }
      return getPrivateLocation(listingId);
    } catch (_) {
      // permission-denied (aucun document d'accès pour ce client) ou toute
      // autre erreur réseau : traité uniformément comme "pas d'accès",
      // jamais remonté comme exception à l'UI.
      return null;
    }
  }

  /// Existe-t-il déjà une demande de visite non terminée (pending/proposed)
  /// pour cette annonce et ce client ? Évite une double soumission depuis
  /// `listing_detail_screen.dart` (Mission 10 — aucun dédoublonnage
  /// n'existait avant ce chantier). Filtre côté client sur la liste déjà
  /// chargée par [visitRequestsAsClient] plutôt qu'une nouvelle requête
  /// composite, pour ne nécessiter aucun nouvel index Firestore.
  static Stream<RealEstateVisitRequest?> activeVisitRequestFor({
    required String listingId,
    required String clientId,
  }) {
    return visitRequestsAsClient(clientId).map((requests) {
      for (final r in requests) {
        if (r.listingId == listingId &&
            (r.status == 'pending' || r.status == 'proposed')) {
          return r;
        }
      }
      return null;
    });
  }

  // ── Images ───────────────────────────────────────────────────────────────

  static Future<String> uploadImage(
      XFile file, String listingId, int index) async {
    final ref = _storage.ref('real_estate/$listingId/img_$index.jpg');
    final bytes = await file.readAsBytes();
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  static Future<List<String>> uploadImages(
      List<XFile> files, String listingId) async {
    final urls = <String>[];
    for (var i = 0; i < files.length; i++) {
      urls.add(await uploadImage(files[i], listingId, i));
    }
    return urls;
  }

  /// Master Prompt "Immobilier V6.2" — Mission 8 : upload d'une photo
  /// ajoutée pendant une ÉDITION — chemin distinct de [uploadImage] (basé
  /// sur un horodatage, pas un index positionnel) pour ne jamais risquer
  /// d'écraser une photo déjà existante à un index déjà utilisé par une
  /// image conservée.
  static Future<String> uploadEditedImage(XFile file, String listingId) async {
    final ref = _storage.ref(
        'real_estate/$listingId/edit_${DateTime.now().microsecondsSinceEpoch}.jpg');
    final bytes = await file.readAsBytes();
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return ref.getDownloadURL();
  }

  /// Master Prompt "Immobilier V6.2" — Mission 8 : suppression Storage
  /// best-effort d'une photo retirée en édition — appelée UNIQUEMENT après
  /// que la mise à jour Firestore a déjà réussi (jamais avant, jamais si la
  /// sauvegarde a échoué). Un échec ici ne doit jamais remettre en cause la
  /// sauvegarde déjà commise — au pire un fichier orphelin reste dans
  /// Storage, jamais une annonce dans un état incohérent.
  static Future<void> deleteImageByUrl(String url) async {
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {}
  }

  // ── Agents ───────────────────────────────────────────────────────────────

  static Future<RealEstateAgent?> getAgent(String uid) async {
    final doc = await _db.collection('real_estate_agents').doc(uid).get();
    return doc.exists ? RealEstateAgent.fromDoc(doc) : null;
  }

  static Future<void> updateAgentPhoto(String uid, String? url) =>
      _db.collection('real_estate_agents').doc(uid).update({
        'photoUrl': url ?? FieldValue.delete(),
      });

  static Future<void> submitAgentRequest({
    required String name,
    required String phone,
    String? agencyName,
    String? city,
  }) async {
    await _fn.httpsCallable('submitRealEstateAgentRequest').call({
      'name': name,
      'phone': phone,
      if (agencyName != null) 'agencyName': agencyName,
      if (city != null) 'city': city,
    });
  }

  // ── Visites ──────────────────────────────────────────────────────────────

  static Future<String> requestVisit({
    required String listingId,
    String? preferredDate,
    String? message,
  }) async {
    final result = await _fn.httpsCallable('requestPropertyVisit').call({
      'listingId': listingId,
      if (preferredDate != null) 'preferredDate': preferredDate,
      if (message != null) 'message': message,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return data['requestId'] as String;
  }

  static Future<void> respondToVisit({
    required String requestId,
    required String action, // propose | confirm | decline | cancel
    String? proposedDate,
  }) async {
    await _fn.httpsCallable('respondToVisitRequest').call({
      'requestId': requestId,
      'action': action,
      if (proposedDate != null) 'proposedDate': proposedDate,
    });
  }

  static Stream<List<RealEstateVisitRequest>> visitRequestsAsClient(
          String uid) =>
      _db
          .collection('real_estate_visit_requests')
          .where('clientId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((s) => s.docs.map(RealEstateVisitRequest.fromDoc).toList());

  static Stream<List<RealEstateVisitRequest>> visitRequestsAsAgent(
          String agentId) =>
      _db
          .collection('real_estate_visit_requests')
          .where('agentId', isEqualTo: agentId)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((s) => s.docs.map(RealEstateVisitRequest.fromDoc).toList());
}
