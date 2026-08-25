import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'web_router.dart';
import 'web_theme.dart';

class WebApp extends StatelessWidget {
  const WebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'AZ Express – Livraison Express en Côte d\'Ivoire',
      debugShowCheckedModeBanner: false,
      routerConfig: webRouter,
      scrollBehavior: _WebScrollBehavior(),
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

// Allow mouse drag scrolling on web
class _WebScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
      };
}
