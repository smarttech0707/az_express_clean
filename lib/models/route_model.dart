import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteModel {
  final List<LatLng> points;
  final double distanceKm;
  final int etaMinutes;
  final String distanceText;
  final String etaText;
  final int estimatedPrice; // FCFA

  /// `true` quand aucun itinéraire routier n'a pu être obtenu : [points] est
  /// alors une ligne droite, [distanceKm] un vol d'oiseau et [etaMinutes] une
  /// durée à vitesse fixe. L'interface doit le dire au lieu de présenter ces
  /// valeurs comme un trajet réel.
  final bool isEstimate;

  const RouteModel({
    required this.points,
    required this.distanceKm,
    required this.etaMinutes,
    required this.distanceText,
    required this.etaText,
    required this.estimatedPrice,
    this.isEstimate = false,
  });

  bool get isEmpty => points.isEmpty;
  bool get isNotEmpty => points.isNotEmpty;

  static RouteModel empty() => const RouteModel(
        points: [],
        distanceKm: 0,
        etaMinutes: 0,
        distanceText: '--',
        etaText: '--',
        estimatedPrice: 0,
      );

  RouteModel copyWith({
    List<LatLng>? points,
    double? distanceKm,
    int? etaMinutes,
    String? distanceText,
    String? etaText,
    int? estimatedPrice,
    bool? isEstimate,
  }) =>
      RouteModel(
        points: points ?? this.points,
        distanceKm: distanceKm ?? this.distanceKm,
        etaMinutes: etaMinutes ?? this.etaMinutes,
        distanceText: distanceText ?? this.distanceText,
        etaText: etaText ?? this.etaText,
        estimatedPrice: estimatedPrice ?? this.estimatedPrice,
        isEstimate: isEstimate ?? this.isEstimate,
      );

  // ── Formatage ─────────────────────────────────────────────────────────────

  static String formatEta(int minutes) {
    if (minutes <= 0) return '< 1 min';
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '${h}h $m min' : '${h}h';
  }

  static String formatDistance(double km) {
    if (km <= 0) return '0 m';
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  /// Prix estimé en FCFA (base 500 + 200 FCFA/km, arrondi à 50)
  static int estimatePrice(double distanceKm) {
    const base = 500;
    const perKm = 200;
    if (distanceKm <= 0) return base;
    final raw = base + (distanceKm * perKm).round();
    return ((raw + 24) ~/ 50) * 50; // arrondi supérieur à 50
  }

  /// ETA à 25 km/h (moto en ville)
  static int estimateEta(double distanceKm) {
    if (distanceKm <= 0) return 1;
    return ((distanceKm / 25) * 60).round().clamp(1, 180);
  }

  /// Résout la distance à utiliser pour un calcul tarifaire à partir d'un
  /// itinéraire éventuellement chargé (Lot 1.1).
  ///
  /// POURQUOI : un itinéraire marqué [isEstimate] (ligne droite de repli,
  /// vitesse fixe) n'est PAS un itinéraire routier réel. Il ne doit jamais
  /// être traité comme tel pour une distance facturée, même s'il contient
  /// des points et une distance positive. Dans ce cas comme dans le cas où
  /// aucun itinéraire n'est encore disponible, on retombe sur la distance
  /// à vol d'oiseau fournie par l'appelant (même méthode de repli dans les
  /// deux cas : seule la provenance diffère). Aucun barème n'est modifié
  /// ici — [TarifService.compute] reste la seule source du prix.
  static ({double distanceKm, bool isRealRoute}) resolveTariffDistance({
    required RouteModel route,
    required double haversineFallbackKm,
  }) {
    final isRealRoute =
        route.isNotEmpty && route.distanceKm > 0 && !route.isEstimate;
    return (
      distanceKm: isRealRoute ? route.distanceKm : haversineFallbackKm,
      isRealRoute: isRealRoute,
    );
  }

  /// Vrai si au moins un des tronçons non vides de [legs] est une estimation
  /// (ligne droite de repli) : l'écran doit alors afficher [RouteEstimateNotice].
  /// Partagé entre les écrans client et livreur pour une seule règle de vérité.
  static bool shouldShowEstimateNotice(Iterable<RouteModel> legs) =>
      legs.any((r) => r.isNotEmpty && r.isEstimate);
}
