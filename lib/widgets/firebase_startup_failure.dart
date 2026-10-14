import 'package:flutter/material.dart';

/// No Firebase-dependent provider is mounted when startup fails.
class FirebaseStartupFailure extends StatelessWidget {
  const FirebaseStartupFailure({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 48),
                    SizedBox(height: 16),
                    Text('AZ Express ne peut pas démarrer',
                        textAlign: TextAlign.center),
                    SizedBox(height: 12),
                    Text(
                      'Les services sont indisponibles. Vérifiez votre connexion '
                      'et relancez l’application. Si le problème persiste, '
                      'contactez le support AZ Express.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
