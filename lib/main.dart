import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';

import 'l10n/app_text.dart';
import 'theme/app_theme.dart';
import 'screens/home/home_screen.dart';
import 'services/notification_service.dart';
import 'services/firestore_service.dart';
import 'web/web_app.dart';
import 'marketplace/providers/mp_provider.dart';
import 'marketplace/providers/mp_favorites_provider.dart';
import 'ekbine/providers/ek_provider.dart';
import 'providers/az_ia_provider.dart';
import 'providers/active_city_provider.dart';
import 'event/providers/event_provider.dart';
import 'widgets/az_ia/az_ia_floating_assistant.dart';

// ignore: unused_element
final _analytics = FirebaseAnalytics.instance;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // C2 — Canal de communication avec le ForegroundService (doit être avant runApp)
  if (!kIsWeb) FlutterForegroundTask.initCommunicationPort();

  // ── Initialisation Firebase — ne doit JAMAIS empêcher runApp() ───────────
  //
  // ÉCRAN NOIR WEB (cause racine) : toutes les options de
  // `DefaultFirebaseOptions.web` viennent de `String.fromEnvironment(...)`,
  // dont la valeur par défaut implicite est la chaîne vide. Un
  // `flutter build web --release` lancé SANS `--dart-define-from-file=.env`
  // compile donc sans erreur, mais produit des options entièrement vides ;
  // `Firebase.initializeApp` échoue alors à l'exécution, l'exception n'était
  // ni du type `duplicate-app` ni rattrapée, et remontait hors de `main()`
  // AVANT `runApp()` — aucune interface Flutter n'était jamais montée, d'où
  // un écran noir sur TOUTES les routes, y compris les pages purement
  // statiques (/confidentialite, /delete-account) qui n'ont aucun besoin de
  // Firebase pour s'afficher.
  //
  // Android y échappait par accident : le plugin natif initialise déjà
  // l'application par défaut depuis `google-services.json`, donc notre appel
  // levait `duplicate-app` — le seul code que l'ancien `catch` tolérait.
  //
  // Le correctif ne masque pas le problème : l'échec est journalisé
  // explicitement et exposé à l'interface, mais il ne peut plus empêcher le
  // démarrage.
  final startupDiagnostic = await _initializeFirebase();
  final firebaseInitialized = startupDiagnostic == null;
  if (startupDiagnostic != null) {
    debugPrint('DÉMARRAGE AZ EXPRESS — Firebase indisponible : '
        '$startupDiagnostic');
  }

  // L'attestation démarre immédiatement, mais ne bloque plus le premier
  // rendu. Les consommateurs Firebase différés attendent explicitement cette
  // Future avant d'émettre leur première requête.
  // App Check n'est jamais activé sur Web (aucune clé reCAPTCHA configurée),
  // ni quand Firebase n'a pas pu s'initialiser (l'appel échouerait).
  final appCheckReady = (kIsWeb || startupDiagnostic != null)
      ? Future<void>.value()
      : _activateAppCheck();

  // ── Crashlytics (mobile only — not supported on web) ─────────────
  if (!kIsWeb) {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (firebaseInitialized) {
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      } else {
        debugPrint('Crashlytics indisponible avant initialisation Firebase.');
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('ERREUR ASYNCHRONE NON CAPTURÉE : $error');
      debugPrintStack(stackTrace: stack);
      if (firebaseInitialized) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      } else {
        debugPrint('Crashlytics indisponible avant initialisation Firebase.');
      }
      return true;
    };
  }

  // ── Persistence offline ───────────────────────────────────────────
  // Jamais tentée si Firebase n'est pas initialisé : `instance` lèverait et
  // tuerait à nouveau le démarrage avant runApp().
  if (startupDiagnostic == null) {
    try {
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: 52428800, // 50 MB — CACHE_SIZE_UNLIMITED est déprécié
      );
    } catch (e) {
      debugPrint('Persistance Firestore non appliquée : $e');
    }
  }

  runApp(kIsWeb
      ? WebApp(startupDiagnostic: startupDiagnostic)
      : MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => MpProvider()),
            ChangeNotifierProvider(create: (_) => MpFavoritesProvider()),
            ChangeNotifierProvider(create: (_) => EkProvider()),
            ChangeNotifierProvider(
              create: (_) => AzIaProvider(initializationReady: appCheckReady),
            ),
            ChangeNotifierProvider(create: (_) => EventProvider()),
            ChangeNotifierProvider(create: (_) => ActiveCityProvider()),
          ],
          child: const AZExpressApp(),
        ));

  if (!kIsWeb && startupDiagnostic == null) {
    unawaited(_initializeDeferred(appCheckReady));
  }
}

/// Initialise Firebase sans jamais lever.
///
/// @return `null` si Firebase est prêt, sinon une description courte et non
/// sensible du problème (aucune clé, aucune valeur de configuration).
Future<String?> _initializeFirebase() async {
  late final FirebaseOptions options;
  try {
    options = DefaultFirebaseOptions.currentPlatform;
  } catch (e) {
    return 'plateforme non configurée ($e)';
  }

  // Détection explicite d'un build sans `--dart-define-from-file=.env` :
  // inutile d'appeler initializeApp avec des options vides, l'échec est
  // certain et le diagnostic serait moins clair.
  if (options.apiKey.isEmpty || options.projectId.isEmpty) {
    return 'configuration absente — relancer le build avec '
        '--dart-define-from-file=.env';
  }

  try {
    await Firebase.initializeApp(options: options);
    return null;
  } on FirebaseException catch (e) {
    // Android : le plugin natif a déjà initialisé l'app par défaut depuis
    // google-services.json — ce n'est pas une erreur.
    if (e.code == 'duplicate-app') return null;
    return 'FirebaseException ${e.code}';
  } catch (e) {
    return '${e.runtimeType}';
  }
}

Future<void> _initializeDeferred(Future<void> appCheckReady) async {
  await appCheckReady;
  // La permission notification ne doit bloquer ni le rendu ni les autres
  // initialisations réseau.
  unawaited(NotificationService().init());

  final authFuture = _ensureAnonymousAuth();

  try {
    await Future.wait([
      authFuture,
      FirestoreService().loadCommissionConfig(),
    ]);
  } catch (e, stack) {
    FirebaseCrashlytics.instance
        .recordError(e, stack, reason: 'Deferred initialization failed');
  }
}

Future<void> _ensureAnonymousAuth() async {
  if (FirebaseAuth.instance.currentUser != null) return;
  try {
    await FirebaseAuth.instance
        .signInAnonymously()
        .timeout(const Duration(seconds: 5));
  } catch (e, stack) {
    FirebaseCrashlytics.instance
        .recordError(e, stack, reason: 'Anonymous auth failed');
  }
}

Future<void> _activateAppCheck() async {
  try {
    await FirebaseAppCheck.instance.activate(
      // ignore: deprecated_member_use
      androidProvider:
          kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      // ignore: deprecated_member_use
      appleProvider:
          kDebugMode ? AppleProvider.debug : AppleProvider.deviceCheck,
    );
  } catch (e, stack) {
    FirebaseCrashlytics.instance
        .recordError(e, stack, reason: 'App Check activation failed');
  }
}

class AZExpressApp extends StatefulWidget {
  const AZExpressApp({super.key});

  @override
  State<AZExpressApp> createState() => _AZExpressAppState();
}

class _AZExpressAppState extends State<AZExpressApp> {
  Locale _locale = const Locale('fr');

  void _setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppLanguage(
      locale: _locale,
      onLocaleChanged: _setLocale,
      child: ScreenUtilInit(
        designSize: const Size(390, 844),
        minTextAdapt: true,
        splitScreenMode: true,
        // MaterialApp in child (not builder) so ScreenUtil rebuilds
        // don't recreate the entire widget tree and reset image decoding.
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: NotificationService.navigatorKey,
          locale: _locale,
          supportedLocales: AppText.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          localeResolutionCallback: (locale, supportedLocales) {
            for (final supported in supportedLocales) {
              if (supported.languageCode == locale?.languageCode) {
                return supported;
              }
            }
            return const Locale('fr');
          },
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.system,
          builder: (context, child) => AzIaFloatingAssistant(
            child: child ?? const SizedBox.shrink(),
          ),
          home: const HomeScreen(),
        ),
        builder: (_, child) => child ?? const SizedBox.shrink(),
      ),
    );
  }
}
