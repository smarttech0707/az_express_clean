import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../constants/app_build.dart';

/// LOT 6.2/6.3 SECURITY — empêche une application trop ancienne de tenter un
/// paiement wallet incompatible avec les règles Firestore durcies (LOT 6 :
/// `lastPaidOrderId` sur `orders` ; LOT 6.1 : `lastPaidReservationId` sur
/// `event_reservations`). Sans ce garde-fou, un build antérieur à ce
/// correctif échouerait avec un `permission-denied` Firestore brut et
/// incompréhensible dès que la règle durcie serait réellement déployée —
/// ce service transforme cet échec silencieux en une invite claire de mise
/// à jour, avant même de tenter l'écriture.
///
/// **Limite assumée, pas cachée (LOT 6.3)** : ce contrôle protège les
/// utilisateurs du build qui le CONTIENT. Un build antérieur à son ajout ne
/// l'exécute jamais — il ne bénéficiera d'aucune invite et verra la vraie
/// erreur Firestore (`permission-denied`) le jour où la règle durcie sera
/// réellement déployée. `minWalletPaymentBuild` n'est donc PAS une solution
/// rétroactive : c'est un garde-fou pour les builds à venir, à combiner
/// obligatoirement avec l'ordre de déploiement documenté dans le rapport
/// LOT 6.3 (nouvelle app déployée et adoptée AVANT toute règle financière
/// durcie), jamais un substitut à cet ordre.
///
/// Lecture d'un document PUBLIC (`config/app_version`, déjà `allow read: if
/// true` — aucune règle à modifier) exposant `minWalletPaymentBuild` (int,
/// optionnel). Repli délibérément PERMISSIF : document absent, champ absent,
/// ou erreur réseau/lecture -> considéré compatible, un paiement légitime ne
/// doit jamais être bloqué par un souci de configuration ou de
/// connectivité côté vérification elle-même. Ce service ne fait que guider
/// l'utilisateur avant l'écriture ; la vraie garantie de sécurité reste,
/// comme avant, entièrement portée par les règles Firestore.
class WalletPaymentCompatibilityService {
  const WalletPaymentCompatibilityService._();

  /// Pure, testable sans Firestore/Flutter : `true` si `currentBuild` est
  /// assez récent pour satisfaire `minRequiredBuild` (`null` = aucune
  /// exigence, toujours compatible).
  static bool isCompatible(int currentBuild, int? minRequiredBuild) {
    if (minRequiredBuild == null) return true;
    return currentBuild >= minRequiredBuild;
  }

  /// Lecture réelle de `config/app_version.minWalletPaymentBuild`. Isolée
  /// (plutôt qu'en ligne dans [ensureCompatible]) pour être remplaçable par
  /// injection en test — voir `fetchMinRequiredBuild` ci-dessous. Ne lève
  /// jamais : toute erreur retombe sur `null` (aucune exigence connue).
  static Future<int?> defaultFetchMinRequiredBuild() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('config')
          .doc('app_version')
          .get();
      final raw = snap.data()?['minWalletPaymentBuild'];
      return raw is num ? raw.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  /// À appeler juste avant toute transaction de paiement WALLET (jamais pour
  /// cash/future, qui ne sont pas concernés par `lastPaidOrderId`/
  /// `lastPaidReservationId`). Retourne `true` si l'appelant peut
  /// poursuivre ; `false` si un dialogue de mise à jour a déjà été affiché
  /// (l'appelant doit alors interrompre son flux, ne rien débiter).
  ///
  /// [fetchMinRequiredBuild] : point d'injection pour les tests (version
  /// compatible/incompatible/absente/erreur réseau) — en production, utilise
  /// toujours [defaultFetchMinRequiredBuild] (lecture Firestore réelle).
  static Future<bool> ensureCompatible(
    BuildContext context, {
    Future<int?> Function()? fetchMinRequiredBuild,
  }) async {
    int? minRequiredBuild;
    try {
      minRequiredBuild =
          await (fetchMinRequiredBuild ?? defaultFetchMinRequiredBuild)();
    } catch (_) {
      // Repli permissif explicite, même si un fetcher injecté lève au lieu
      // de retourner null — voir doc de classe.
      return true;
    }

    if (isCompatible(kAppBuildNumber, minRequiredBuild)) return true;
    if (!context.mounted) return false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Mise à jour requise'),
        content: const Text(
          'Une mise à jour de sécurité est nécessaire pour continuer à payer '
          'par wallet. Merci de mettre à jour l\'application avant de '
          'réessayer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Compris'),
          ),
        ],
      ),
    );
    return false;
  }
}
