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

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (e) {
    if (e.code != 'duplicate-app') rethrow;
    // Firebase déjà initialisé côté natif Android (JVM survit entre lancements)
  }

  // L'attestation démarre immédiatement, mais ne bloque plus le premier
  // rendu. Les consommateurs Firebase différés attendent explicitement cette
  // Future avant d'émettre leur première requête.
  final appCheckReady = kIsWeb ? Future<void>.value() : _activateAppCheck();

  // ── Crashlytics (mobile only — not supported on web) ─────────────
  if (!kIsWeb) {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('ERREUR ASYNCHRONE NON CAPTURÉE : $error');
      debugPrintStack(stackTrace: stack);
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }

  // ── Persistence offline ───────────────────────────────────────────
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: 52428800, // 50 MB — CACHE_SIZE_UNLIMITED est déprécié
  );

  runApp(kIsWeb
      ? const WebApp()
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

  if (!kIsWeb) unawaited(_initializeDeferred(appCheckReady));
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
