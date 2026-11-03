import 'package:flutter/material.dart';

import '../services/firebase_project_guard.dart';

/// Écran bloquant d'un build de test relié au mauvais projet Firebase.
///
/// Volontairement sans Provider, sans Firebase, sans navigation : aucune lecture
/// ni écriture métier, aucune commande, aucun paiement ne peut partir d'ici.
/// Aucun identifiant de projet ni clé n'est affiché.
class WrongFirebaseProjectScreen extends StatelessWidget {
  const WrongFirebaseProjectScreen({super.key});

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
                    Icon(Icons.gpp_bad_rounded, size: 48),
                    SizedBox(height: 16),
                    Text(FirebaseProjectGuard.blockedCode,
                        key: Key('wrong-firebase-project-code'),
                        textAlign: TextAlign.center),
                    SizedBox(height: 12),
                    Text(
                      'Cette version de test n\'est pas reliée au projet de '
                      'préproduction attendu. Elle a été bloquée avant toute '
                      'opération : ne l\'utilisez pas et prévenez l\'équipe technique.',
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
