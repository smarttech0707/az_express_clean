import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import 'notification_service.dart';

/// Autorisations système pour lesquelles une explication précède l'invite (mission M2.9).
enum PermissionKind { notifications, location, driverLocation, camera, microphone, photos }

class PermissionCopy {
  const PermissionCopy(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

/// Explique à quoi sert une autorisation AVANT l'invite système, au moment où la fonction en a besoin.
///
/// Règles :
/// - l'invite système n'est jamais déclenchée par l'appelant tant que [prepare] n'a pas répondu `true` ;
/// - un refus ("Plus tard") ne bloque rien : l'appelant continue sans l'autorisation et la même explication n'est pas
///   redemandée pendant la session (pas de harcèlement) ;
/// - une explication acceptée n'est plus montrée (l'invite système n'apparaît de toute façon qu'une fois) ;
/// - une autorisation déjà accordée ne montre rien.
class PermissionPrimer {
  PermissionPrimer._();

  static const copy = <PermissionKind, PermissionCopy>{
    PermissionKind.notifications: PermissionCopy(
      Icons.notifications_active_rounded,
      'Rester informé de vos commandes',
      'AZ Express vous envoie des notifications pour suivre l\'état de vos commandes, confirmer vos paiements et vous '
          'alerter en cas de problème de sécurité. Vous pouvez continuer sans les autoriser et les activer plus tard '
          'dans les réglages de votre téléphone.',
    ),
    PermissionKind.location: PermissionCopy(
      Icons.location_on_rounded,
      'Utiliser votre position',
      'Votre position sert à trouver les services proches, permettre au livreur de vous rejoindre et calculer prix et '
          'délais. Sans elle, vous pouvez saisir votre adresse à la main.',
    ),
    PermissionKind.driverLocation: PermissionCopy(
      Icons.my_location_rounded,
      'Partager votre position en service',
      'Pour recevoir des courses proches et permettre au client de suivre sa livraison, AZ Express utilise votre '
          'position tant que vous êtes en ligne. Sur iPhone, elle n\'est utilisée en arrière-plan que pendant une '
          'livraison en cours. Sans elle, vous ne pouvez pas recevoir de courses.',
    ),
    PermissionKind.camera: PermissionCopy(
      Icons.photo_camera_rounded,
      'Utiliser l\'appareil photo',
      'L\'appareil photo sert à prendre une photo (produit, pièce justificative, selfie ou preuve de livraison) que '
          'vous choisissez d\'envoyer. Vous pouvez aussi choisir une image déjà enregistrée.',
    ),
    PermissionKind.microphone: PermissionCopy(
      Icons.mic_rounded,
      'Utiliser le microphone',
      'Le microphone sert à enregistrer vos messages vocaux ou à dicter votre message. Vous pouvez continuer en '
          'écrivant.',
    ),
    PermissionKind.photos: PermissionCopy(
      Icons.photo_library_rounded,
      'Joindre une photo',
      'AZ Express n\'accède qu\'à l\'image que vous choisissez pour la joindre (produit, annonce, profil, support). '
          'Vous pouvez continuer sans photo.',
    ),
  };

  static const _acceptedPrefix = 'perm_primer_accepted_';
  static const _notificationsAskedKey = 'perm_primer_notifications_asked';

  static final Set<PermissionKind> _declinedThisSession = {};
  static final Map<PermissionKind, Future<bool>> _inFlight = {};

  /// Contexte utilisé quand l'appelant n'en fournit pas (services, écrans sans contexte).
  static BuildContext? _fallbackContext() => NotificationService.navigatorKey.currentContext;

  @visibleForTesting
  static void debugReset() {
    _declinedThisSession.clear();
    _inFlight.clear();
  }

  /// Retourne `true` si l'appelant peut déclencher l'invite système (ou l'action qui la déclenche).
  /// Retourne `false` si l'utilisateur a choisi de continuer sans autoriser, ou si aucune explication ne peut être
  /// affichée (jamais d'invite système sans explication).
  static Future<bool> prepare(
    PermissionKind kind, {
    BuildContext? context,
    Future<bool> Function()? alreadyGranted,
  }) {
    if (kIsWeb) return Future.value(true); // le navigateur affiche sa propre invite
    final running = _inFlight[kind];
    if (running != null) return running; // plusieurs appels simultanés : une seule explication
    final future = _prepare(kind, context, alreadyGranted).whenComplete(() {
      // Bloc volontaire : retourner le Future retiré ferait attendre whenComplete sur lui-même.
      _inFlight.remove(kind);
    });
    _inFlight[kind] = future;
    return future;
  }

  static Future<bool> _prepare(
    PermissionKind kind,
    BuildContext? context,
    Future<bool> Function()? alreadyGranted,
  ) async {
    if (alreadyGranted != null) {
      try {
        if (await alreadyGranted()) return true;
      } catch (_) {}
    }
    if (_declinedThisSession.contains(kind)) return false;
    final prefs = await _prefs();
    if (prefs?.getBool('$_acceptedPrefix${kind.name}') == true) return true;

    final ctx = context != null && context.mounted ? context : _fallbackContext();
    if (ctx == null || !ctx.mounted) return false;
    final accepted = await _showExplanation(ctx, kind);
    if (accepted) {
      unawaited(_remember(prefs, '$_acceptedPrefix${kind.name}'));
      return true;
    }
    _declinedThisSession.add(kind);
    return false;
  }

  /// Écriture sans attente : le cache mémoire est déjà à jour, l'écriture disque ne doit pas retarder l'invite.
  static Future<void> _remember(SharedPreferences? prefs, String key) async {
    try {
      await prefs?.setBool(key, true);
    } catch (_) {}
  }

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _showExplanation(BuildContext context, PermissionKind kind) async {
    final c = copy[kind]!;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        key: Key('permission_primer_${kind.name}'),
        icon: Icon(c.icon, size: 36, color: AppColors.primaryAction),
        title: Text(c.title, textAlign: TextAlign.center),
        content: Text(c.body),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            key: const Key('permission_primer_later'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            key: const Key('permission_primer_continue'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primaryAction),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
    return result == true;
  }

  // ── Localisation ───────────────────────────────────────────────────────────

  /// Remplace `Geolocator.requestPermission()` : explique d'abord, puis demande. Si l'utilisateur choisit « Plus tard »,
  /// retourne l'état actuel (`denied`) sans invite système : les appelants gèrent déjà ce cas.
  static Future<LocationPermission> requestLocation({BuildContext? context, bool driver = false}) async {
    final current = await Geolocator.checkPermission();
    if (current == LocationPermission.always ||
        current == LocationPermission.whileInUse ||
        current == LocationPermission.deniedForever) {
      return current; // rien à demander : même résultat que requestPermission()
    }
    final kind = driver ? PermissionKind.driverLocation : PermissionKind.location;
    // prepare() revérifie context.mounted avant d'afficher quoi que ce soit.
    // ignore: use_build_context_synchronously
    if (!await prepare(kind, context: context)) return current;
    return Geolocator.requestPermission();
  }

  // ── Caméra, photos, microphone ─────────────────────────────────────────────

  /// À appeler avant `ImagePicker.pickImage/pickMultiImage/pickVideo` ; `false` = continuer sans photo.
  static Future<bool> prepareImage(ImageSource source, {BuildContext? context}) {
    if (source == ImageSource.camera) {
      return prepare(PermissionKind.camera,
          context: context, alreadyGranted: () => Permission.camera.isGranted);
    }
    return prepare(PermissionKind.photos, context: context);
  }

  /// À appeler avant d'enregistrer ou de dicter ; `false` = continuer en écrivant.
  static Future<bool> prepareMicrophone({BuildContext? context}) => prepare(PermissionKind.microphone,
      context: context, alreadyGranted: () => Permission.microphone.isGranted);

  // ── Notifications ──────────────────────────────────────────────────────────

  /// Demande les notifications une seule fois, après la connexion, avec explication. Un refus de l'explication ou de
  /// l'invite n'est jamais redemandé automatiquement (l'utilisateur peut les activer dans les réglages).
  static Future<void> requestNotifications({
    required Future<bool> Function() isAuthorized,
    required Future<void> Function() requestSystem,
    BuildContext? context,
  }) async {
    if (kIsWeb) return;
    try {
      if (await isAuthorized()) return;
      final prefs = await _prefs();
      if (prefs?.getBool(_notificationsAskedKey) == true) return;
      // ignore: use_build_context_synchronously
      final proceed = await prepare(PermissionKind.notifications, context: context);
      // Aucune explication affichable (pas de contexte) : on réessaiera à la prochaine connexion.
      if (!proceed && !_declinedThisSession.contains(PermissionKind.notifications)) return;
      unawaited(_remember(prefs, _notificationsAskedKey));
      if (!proceed) return;
      await requestSystem();
    } catch (_) {}
  }
}
