import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Mode « émulateurs Firebase » des APK de test (voir `test-env/`).
///
/// Activé seulement par `--dart-define=USE_FIREBASE_EMULATORS=true`. Ce mode est
/// fermé par construction : l'application n'utilise AUCUNE option de production
/// (les options ci-dessous sont factices, projet `demo-…`), refuse de démarrer si
/// le projet réellement initialisé n'est pas un projet `demo-…`, et ne se connecte
/// qu'à une adresse du réseau local. Si les émulateurs sont injoignables, les
/// appels échouent ; ils ne basculent jamais sur la production.
class FirebaseEmulatorConfig {
  const FirebaseEmulatorConfig._();

  static const bool enabled = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  static const String host = String.fromEnvironment('EMULATOR_HOST');
  static const String projectId = 'demo-az-express';
  static const int authPort =
      int.fromEnvironment('EMULATOR_AUTH_PORT', defaultValue: 9099);
  static const int firestorePort =
      int.fromEnvironment('EMULATOR_FIRESTORE_PORT', defaultValue: 8080);
  static const int functionsPort =
      int.fromEnvironment('EMULATOR_FUNCTIONS_PORT', defaultValue: 5001);
  static const int storagePort =
      int.fromEnvironment('EMULATOR_STORAGE_PORT', defaultValue: 9199);

  // Émulateur Android (10.0.2.2) ou adresse privée du PC : jamais un nom de
  // domaine public, jamais « localhost ». 127.0.0.2 n'est admis que pour le tunnel USB (pas 127.0.0.1 : les plugins Firebase Android le réécrivent en 10.0.2.2, injoignable sur un téléphone)
  // (`adb reverse`, voir test-env/usb-isolation.ps1) : sur le téléphone, la boucle locale
  // ne peut atteindre ni Internet ni le réseau local, seulement les ports redirigés vers le PC.
  static final RegExp _lanHost = RegExp(
      r'^(127\.0\.0\.2|10\.0\.2\.2|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})$');

  static bool isSafeHost(String value) => _lanHost.hasMatch(value);

  static bool isDemoProject(String value) => value.startsWith('demo-');

  /// Options factices : aucune clé ni identifiant de production dans l'APK de test.
  static const FirebaseOptions options = FirebaseOptions(
    // Chaîne synthétique au format attendu par firebase-installations ; identique à celle du google-services.json factice.
    apiKey: 'AIzaSyDEMO-az-express-local-emulator-00',
    appId: '1:000000000000:android:0000000000000000',
    messagingSenderId: '000000000000',
    projectId: projectId,
    storageBucket: '$projectId.appspot.com',
  );

  /// Initialise Firebase en mode émulateurs. Retourne `null` si tout est prêt,
  /// sinon un diagnostic court (même contrat que `_initializeFirebase`).
  static Future<String?> initialize() async {
    if (!isSafeHost(host)) {
      return 'EMULATOR_HOST invalide (adresse privée du PC requise)';
    }
    try {
      try {
        await Firebase.initializeApp(options: options);
      } on FirebaseException catch (e) {
        // Android : le plugin natif a déjà initialisé l'app depuis
        // google-services.json ; on vérifie ci-dessous qu'elle est factice.
        if (e.code != 'duplicate-app') rethrow;
      }
      final actual = Firebase.app().options.projectId;
      if (!isDemoProject(actual)) {
        return 'projet Firebase non factice détecté : démarrage refusé';
      }
      await FirebaseAuth.instance.useAuthEmulator(host, authPort);
      FirebaseFirestore.instance.useFirestoreEmulator(host, firestorePort);
      FirebaseFunctions.instanceFor(region: 'europe-west1')
          .useFunctionsEmulator(host, functionsPort);
      await FirebaseStorage.instance.useStorageEmulator(host, storagePort);
      return null;
    } catch (e) {
      return 'émulateurs : ${e.runtimeType}';
    }
  }
}
