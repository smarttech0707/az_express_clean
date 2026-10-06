import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'web_router.dart';
import 'web_theme.dart';

class WebApp extends StatelessWidget {
  /// Description courte et non sensible d'un échec d'initialisation Firebase,
  /// ou `null` si tout est prêt. Le site s'affiche dans les deux cas : les
  /// pages statiques (accueil, confidentialité, suppression de compte) n'ont
  /// besoin d'aucun service Firebase pour être rendues. Un échec silencieux
  /// avait produit un écran noir en production — il est désormais visible.
  final String? startupDiagnostic;

  const WebApp({super.key, this.startupDiagnostic});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'AZ Express – Livraison Express en Côte d\'Ivoire',
      debugShowCheckedModeBanner: false,
      routerConfig: webRouter,
      scrollBehavior: _WebScrollBehavior(),
      builder: (context, child) {
        final page = child ?? const SizedBox.shrink();
        if (startupDiagnostic == null) return page;
        return WebStartupBanner.wrap(
          message: startupDiagnostic!,
          child: page,
        );
      },
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: kOrange,
          secondary: kBlue,
          surface: kNavy,
        ),
        scaffoldBackgroundColor: kNavy,
        useMaterial3: true,
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: kOrange,
          selectionColor: Color(0x44FF6B00),
          selectionHandleColor: kOrange,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kNavyCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kDivider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kDivider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kOrange, width: 2),
          ),
          labelStyle: const TextStyle(color: kTextMuted),
          hintStyle: const TextStyle(color: kTextMuted),
        ),
      ),
    );
  }
}

/// Bandeau de diagnostic : rend visible un démarrage dégradé au lieu de le
/// laisser silencieux. Les pages de contenu restent entièrement lisibles.
class WebStartupBanner extends StatelessWidget {
  final String message;

  const WebStartupBanner({super.key, required this.message});

  /// Compose le bandeau au-dessus d'une page, sans rien masquer de celle-ci.
  static Widget wrap({required String message, required Widget child}) {
    return Column(
      children: [
        WebStartupBanner(message: message),
        Expanded(child: child),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF7F1D1D),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Services en ligne indisponibles ($message). '
                  'Les informations de cette page restent consultables.',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Allow mouse drag scrolling on web
class _WebScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
      };
}
