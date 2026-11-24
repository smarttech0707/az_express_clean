# Provenance — copie locale de `flutter_foreground_task` 8.17.0 (Android seulement)

- Origine : paquet `flutter_foreground_task` 8.17.0, https://pub.dev/packages/flutter_foreground_task (dépôt https://github.com/Dev-hwang/flutter_foreground_task), copié depuis le cache Pub (sha256 du paquet verrouillé : `206017ee1bf864f34b8d7bce664a172717caa21af8da23f55866470dfe316644`).
- Licence : MIT, © 2021 Dev-hwang (fichier `LICENSE` inchangé).
- Raison (mission M2.7.2, guideline Apple 2.5.4) : le code iOS du plugin enregistre au lancement une tâche `BGTaskScheduler` et un background fetch dont le travail est vide, même si l'application ne lance jamais le service sur iOS. Cette copie **n'a pas de plateforme iOS** : aucun pod, aucun délégué d'application, aucune tâche d'arrière-plan n'est embarqué dans le build iOS.
- Seule différence avec l'original : dans `pubspec.yaml`, suppression du bloc `ios:` (`pluginClass: FlutterForegroundTaskPlugin`) sous `flutter.plugin.platforms`. Le dossier `ios/`, `example/`, `documentation/`, `test/` et `README.md` ne sont pas copiés. `lib/` (Dart) et `android/` sont identiques octet pour octet (empreintes dans `SHA256SUMS.txt`, contrôlées par `test/third_party/foreground_task_copy_test.dart`).
- Branchement : `dependency_overrides` dans le `pubspec.yaml` de l'application. Android conserve exactement le comportement de la version 8.17.0.
- Mise à jour : ne pas modifier ces fichiers à la main. Pour changer de version, recopier la nouvelle version du cache Pub, retirer le bloc `ios:`, régénérer `SHA256SUMS.txt` et revalider sur appareil Android.
