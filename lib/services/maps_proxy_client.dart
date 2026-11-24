import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Issue d'un appel au proxy Maps (Lot 1.2.1).
///
/// POURQUOI trois états plutôt qu'un simple `null` : [data] et
/// [unavailable] appellent le même repli (données locales/Nominatim ou
/// estimation signalée, jamais Google en direct), mais [denied] est un refus
/// de sécurité (compte suspendu, rôle non éligible, non authentifié) —
/// distinct pour permettre, plus tard, un message dédié à l'utilisateur sans
/// avoir à re-interroger le réseau. Dans TOUS les cas sans donnée, le
/// contrat est identique pour l'appelant : jamais d'appel Google direct.
enum MapsProxyOutcome { data, unavailable, denied }

class MapsProxyResult {
  final MapsProxyOutcome outcome;
  final Map<String, dynamic>? data;

  const MapsProxyResult._(this.outcome, this.data);
  const MapsProxyResult.data(Map<String, dynamic> data)
      : this._(MapsProxyOutcome.data, data);
  const MapsProxyResult.unavailable() : this._(MapsProxyOutcome.unavailable, null);
  const MapsProxyResult.denied() : this._(MapsProxyOutcome.denied, null);

  /// `true` seulement si une donnée exploitable a été obtenue. Dans tous les
  /// autres cas ([unavailable] ou [denied]), l'appelant ne doit **jamais**
  /// tenter un appel Google direct — seulement un repli local déjà prévu
  /// (données locales, Nominatim, estimation clairement signalée).
  bool get hasData => outcome == MapsProxyOutcome.data;
}

/// Appels Google Maps passant par les Cloud Functions (`functions/mapsProxy.js`).
///
/// POURQUOI : la clé des itinéraires, de la recherche et du géocodage reste
/// côté serveur ; l'application ne transporte plus de clé pour ces appels,
/// et ne tente plus jamais d'appel Google direct en repli (Lot 1.2.1) —
/// quelle que soit la cause de l'échec du proxy (refus de sécurité ou panne
/// technique), seul un repli local déjà prévu par l'appelant prend le relais.
class MapsProxyClient {
  MapsProxyClient._();

  static const String route = 'mapsRouteCF';
  static const String autocomplete = 'mapsAutocompleteCF';
  static const String placeDetails = 'mapsPlaceDetailsCF';
  static const String geocode = 'mapsGeocodeCF';

  static const String _region = 'europe-west1';

  /// Codes signifiant un refus de sécurité définitif (compte suspendu, rôle
  /// non éligible, session expirée) : jamais un appel Google direct, jamais
  /// traité comme une simple panne technique, jamais réessayé.
  static const Set<String> _deniedCodes = {'permission-denied', 'unauthenticated'};

  /// Codes jugés transitoires (Lot 1.2.2) — un seul retry possible.
  /// `internal` et `resource-exhausted` en sont délibérément exclus : voir
  /// [_isRetryable].
  static const Set<String> _retryableCodes = {'unavailable', 'deadline-exceeded'};

  /// Au plus un retry, donc deux tentatives au total.
  static const int _maxAttempts = 2;

  /// Délai avant le retry : base + jitter aléatoire, plafonné par le budget
  /// restant (jamais de dépassement du timeout global de l'appelant).
  static const Duration _baseRetryDelay = Duration(milliseconds: 250);
  static const Duration _maxJitter = Duration(milliseconds: 150);

  /// Il faut qu'il reste au moins ce budget après un échec pour tenter un
  /// retry ; sinon la 1ʳᵉ tentative est renvoyée telle quelle.
  static const Duration _minRetryBudget = Duration(milliseconds: 50);

  static final math.Random _random = math.Random();

  /// Test seulement : remplace l'appel réseau. Renvoie le champ `data` de
  /// l'enveloppe pour simuler un succès, `null` pour simuler une
  /// indisponibilité (jamais réessayé — c'est un refus métier, pas une
  /// panne, voir [_isRetryable]), ou lève une [FirebaseFunctionsException]
  /// (ou toute autre exception) pour simuler une erreur précise — classée
  /// et éventuellement réessayée exactement comme un vrai appel réseau.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(
    String name,
    Map<String, dynamic> payload,
  )? debugCall;

  /// Test seulement : remplace le calcul du délai de retry (par défaut
  /// `Duration.zero` pour ne jamais ralentir une suite de tests).
  @visibleForTesting
  static Duration Function(Duration remainingBudget)? debugRetryDelay;

  /// Au plus [_maxAttempts] tentatives vers le proxy (Lot 1.2.2) : jamais
  /// vers Google directement, jamais au-delà du budget [timeout] donné par
  /// l'appelant, jamais sur un refus de sécurité ou une erreur permanente.
  static Future<MapsProxyResult> call(
    String name,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var attempts = 0;
    _Attempt last;
    while (true) {
      attempts++;
      final budget = _remaining(deadline);
      last = await _attempt(name, payload, budget);
      if (last.result.hasData || !last.retryable || attempts >= _maxAttempts) {
        return last.result;
      }
      final remaining = _remaining(deadline);
      if (remaining <= _minRetryBudget) return last.result;
      final delay = _retryDelay(remaining);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_remaining(deadline) <= Duration.zero) return last.result;
      // Boucle : une seule itération supplémentaire possible (_maxAttempts = 2).
    }
  }

  static Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  static Duration _retryDelay(Duration remaining) {
    final compute = debugRetryDelay;
    if (compute != null) return compute(remaining);
    final jitterMs = _random.nextInt(_maxJitter.inMilliseconds + 1);
    final delay = _baseRetryDelay + Duration(milliseconds: jitterMs);
    final cap = remaining - _minRetryBudget;
    if (cap <= Duration.zero) return Duration.zero;
    return delay > cap ? cap : delay;
  }

  /// Une tentative unique, qu'elle passe par [debugCall] (tests) ou par le
  /// vrai appel Cloud Functions. Le budget restant borne la tentative des
  /// deux façons (timeout propre à l'appel réel, et [Future.timeout] ici
  /// pour que [debugCall] soit borné de façon identique en test).
  static Future<_Attempt> _attempt(
    String name,
    Map<String, dynamic> payload,
    Duration budget,
  ) async {
    final test = debugCall;
    try {
      final data = test != null
          ? await test(name, payload)
              .timeout(budget, onTimeout: () => throw TimeoutException(name))
          : await _callReal(name, payload, budget);
      final result = data == null
          ? const MapsProxyResult.unavailable()
          : MapsProxyResult.data(data);
      // Un refus métier sans exception (validation, pas d'itinéraire…) :
      // jamais réessayé, c'est potentiellement permanent.
      return _Attempt(result, retryable: false);
    } catch (e) {
      return _Attempt(_classify(name, e), retryable: _isRetryable(e));
    }
  }

  static Future<Map<String, dynamic>?> _callReal(
    String name,
    Map<String, dynamic> payload,
    Duration budget,
  ) async {
    // Firebase non initialisé (tests unitaires, échec de démarrage) : pas de
    // proxy. Les fonctions exigent aussi un utilisateur connecté ; pharmacie
    // et artisan n'ont pas de session Firebase Auth et gardent le repli.
    if (Firebase.apps.isEmpty) return null;
    if (FirebaseAuth.instance.currentUser == null) return null;
    final result = await FirebaseFunctions.instanceFor(region: _region)
        .httpsCallable(name, options: HttpsCallableOptions(timeout: budget))
        .call<dynamic>(payload);
    return unwrap(result.data);
  }

  /// Classe une exception en refus de sécurité ([MapsProxyOutcome.denied])
  /// ou en panne technique ([MapsProxyOutcome.unavailable]) — jamais autre
  /// chose. Seuls `permission-denied` et `unauthenticated` sont des refus ;
  /// `unavailable`, `deadline-exceeded`, `internal`, `resource-exhausted`,
  /// tout code non reconnu, et toute exception qui n'est même pas une
  /// [FirebaseFunctionsException] (réseau, timeout…) sont des pannes
  /// techniques — jamais un appel Google direct dans aucun des deux cas.
  static MapsProxyResult _classify(String name, Object e) {
    debugPrint('[MapsProxy] $name indisponible ou refusé (${e.runtimeType})');
    if (e is FirebaseFunctionsException && _deniedCodes.contains(e.code)) {
      return const MapsProxyResult.denied();
    }
    return const MapsProxyResult.unavailable();
  }

  /// Un seul retry, uniquement pour une panne jugée transitoire (Lot 1.2.2).
  /// `internal` : fourre-tout pour une exception non gérée — potentiellement
  /// une vérification de sécurité (rôle/suspension) qui a échoué de façon
  /// imprévue ; jamais réessayé automatiquement par prudence.
  /// `resource-exhausted` : c'est le signal explicite de la limitation de
  /// débit — réessayer dans la même fenêtre échouerait presque certainement
  /// à nouveau, sans autre effet que de consommer une tentative pour rien.
  /// `permission-denied`/`unauthenticated` : jamais, ce sont des refus de
  /// sécurité définitifs. Tout code non reconnu : jamais, par défaut prudent.
  static bool _isRetryable(Object e) {
    if (e is FirebaseFunctionsException) {
      return _retryableCodes.contains(e.code);
    }
    // Exception qui n'est même pas un FirebaseFunctionsException : réseau,
    // timeout de transport, désérialisation… traitée comme transitoire,
    // cohérent avec _classify qui range déjà ce cas dans `unavailable`.
    return true;
  }

  /// Extrait `data` d'une enveloppe `{success, error, message, data, code}`.
  /// Tout ce qui n'est pas un succès explicite avec un objet `data` vaut `null`.
  @visibleForTesting
  static Map<String, dynamic>? unwrap(Object? raw) {
    if (raw is! Map) return null;
    if (raw['success'] != true) return null;
    final data = raw['data'];
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data);
  }

  /// Point au format attendu par le serveur.
  static Map<String, double> point(double lat, double lng) =>
      {'lat': lat, 'lng': lng};
}

/// Résultat d'une tentative unique, avec l'information nécessaire à [MapsProxyClient.call]
/// pour décider d'un éventuel retry.
class _Attempt {
  final MapsProxyResult result;
  final bool retryable;
  const _Attempt(this.result, {required this.retryable});
}
