import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mission M2.7.2 : la copie locale de `flutter_foreground_task` (Android seulement) reste identique à la version 8.17.0
/// d'origine, sans iOS, et l'application iOS ne déclare plus ni background fetch ni tâche BGTaskScheduler du plugin.
void main() {
  const root = 'third_party/flutter_foreground_task';

  String sha(File f) => sha256.convert(f.readAsBytesSync()).toString();

  test('Dart et Android identiques à l\'original (empreintes SHA-256)', () {
    final lines = File('$root/SHA256SUMS.txt')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty);
    expect(lines.length, greaterThan(60));
    for (final line in lines) {
      final parts = line.split('  ');
      expect(parts.length, 2, reason: line);
      final file = File('$root/${parts[1]}');
      expect(file.existsSync(), isTrue, reason: parts[1]);
      expect(sha(file), parts[0], reason: 'modifié : ${parts[1]}');
    }
  });

  test('aucun fichier Dart ou Android hors manifeste (pas d\'ajout discret)', () {
    final listed = File('$root/SHA256SUMS.txt')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.split('  ')[1])
        .toSet();
    for (final dir in ['lib', 'android']) {
      for (final f in Directory('$root/$dir').listSync(recursive: true)) {
        if (f is! File) continue;
        final rel = f.path.replaceAll('\\', '/').substring(root.length + 1);
        // Cache Gradle locale (.gradle/), jamais distribuée avec le plugin, régénérée par tout
        // build ayant touché ce sous-projet Android : pas un ajout discret de source.
        if (rel.contains('/.gradle/')) continue;
        expect(listed.contains(rel), isTrue, reason: 'non listé : $rel');
      }
    }
  });

  test('plateforme Android présente, plateforme iOS absente', () {
    expect(Directory('$root/ios').existsSync(), isFalse);
    expect(Directory('$root/android').existsSync(), isTrue);
    final pubspec = File('$root/pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 8.17.0'));
    expect(pubspec, contains('android:'));
    expect(pubspec, contains('package: com.pravera.flutter_foreground_task'));
    expect(pubspec.contains('ios:'), isFalse);
    expect(pubspec.contains('macos:'), isFalse);
  });

  test('licence MIT et provenance conservées', () {
    expect(File('$root/LICENSE').readAsStringSync(), contains('MIT License'));
    expect(File('$root/AZ_PROVENANCE.md').readAsStringSync(),
        contains('206017ee1bf864f34b8d7bce664a172717caa21af8da23f55866470dfe316644'));
  });

  test('l\'application utilise la copie locale', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec,
        matches(RegExp(r'dependency_overrides:\s*\r?\n\s+flutter_foreground_task:\s*\r?\n\s+path: third_party/flutter_foreground_task')));
    final lock = File('pubspec.lock').readAsStringSync();
    expect(lock, contains('path: "third_party/flutter_foreground_task"'));
  });

  test('Info.plist : ni background fetch ni tâche du plugin, location et notifications conservés',
      () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist.contains('BGTaskSchedulerPermittedIdentifiers'), isFalse);
    expect(plist.contains('flutter_foreground_task'), isFalse);
    final modes = RegExp(r'<key>UIBackgroundModes</key>\s*<array>([\s\S]*?)</array>')
        .firstMatch(plist)!
        .group(1)!;
    final values = RegExp(r'<string>([^<]*)</string>')
        .allMatches(modes)
        .map((m) => m.group(1))
        .toList();
    expect(values, ['location', 'remote-notification']);
    expect(utf8.encode(plist).isNotEmpty, isTrue);
  });
}
