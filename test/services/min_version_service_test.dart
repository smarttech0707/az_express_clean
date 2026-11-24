import 'dart:async';
import 'dart:collection';

import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/min_version_service.dart';

void main() {
  test('aucun document : jamais de blocage', () {
    expect(MinVersionService.evaluate(null, 5), MinVersionStatus.ok);
  });
  test('build inconnu (0) : jamais de blocage, même si enforce', () {
    expect(MinVersionService.evaluate({'minBuild': 99, 'enforce': true}, 0),
        MinVersionStatus.ok);
  });
  test('version suffisante : ok', () {
    expect(MinVersionService.evaluate({'minBuild': 14, 'enforce': true}, 14),
        MinVersionStatus.ok);
  });
  test('version ancienne sans enforce : simple recommandation', () {
    expect(MinVersionService.evaluate({'minBuild': 14}, 13),
        MinVersionStatus.updateRecommended);
    expect(MinVersionService.evaluate({'minBuild': 14, 'enforce': 'true'}, 13),
        MinVersionStatus.updateRecommended);
  });
  test('version ancienne avec enforce:true : mise à jour requise', () {
    expect(MinVersionService.evaluate({'minBuild': 14, 'enforce': true}, 13),
        MinVersionStatus.updateRequired);
  });
  test('clés par plateforme : priment sur minBuild, plateforme inconnue ou web = valeurs communes', () {
    final cfg = {'minBuild': 14, 'enforce': true, 'minBuildAndroid': 11, 'minBuildIos': 30};
    expect(MinVersionService.evaluate(MinVersionService.forPlatform(cfg, 'android'), 11), MinVersionStatus.ok);
    expect(MinVersionService.evaluate(MinVersionService.forPlatform(cfg, 'android'), 10), MinVersionStatus.updateRequired);
    expect(MinVersionService.evaluate(MinVersionService.forPlatform(cfg, 'ios'), 29), MinVersionStatus.updateRequired);
    expect(MinVersionService.evaluate(MinVersionService.forPlatform(cfg, null), 13), MinVersionStatus.updateRequired);
    expect(MinVersionService.evaluate(MinVersionService.forPlatform({'minBuild': 14}, 'ios'), 13), MinVersionStatus.updateRecommended);
    expect(MinVersionService.forPlatform(null, 'android'), isNull);
    // clé de plateforme invalide : ignorée
    expect(MinVersionService.forPlatform({'minBuild': 14, 'minBuildAndroid': 'x'}, 'android')!['minBuild'], 14);
  });

  test('lien de mise à jour : https et hôtes connus uniquement', () {
    expect(MinVersionService.safeUpdateUrl('https://az-express-b0469.web.app/telecharger/'),
        'https://az-express-b0469.web.app/telecharger/');
    expect(MinVersionService.safeUpdateUrl('https://play.google.com/store/apps/details?id=com.azexpress.app'), isNotNull);
    expect(MinVersionService.safeUpdateUrl('https://apps.apple.com/app/id1'), isNotNull);
    for (final bad in [
      'http://az-express-b0469.web.app/x',
      'https://evil.example/x',
      'https://az-express-b0469.web.app.evil.example/x',
      'https://user:pw@az-express-b0469.web.app/x',
      'javascript:alert(1)',
      'market://details?id=x',
      '',
      '   ',
    ]) {
      expect(MinVersionService.safeUpdateUrl(bad), isNull, reason: bad);
    }
    expect(MinVersionService.safeUpdateUrl(null), isNull);
    expect(MinVersionService.safeUpdateUrl(42), isNull);
  });

  test('configuration invalide ignorée', () {
    expect(MinVersionService.evaluate({'minBuild': 'x', 'enforce': true}, 1),
        MinVersionStatus.ok);
  });

  group('parseBuild', () {
    test('entiers et décimaux entiers acceptés', () {
      expect(MinVersionService.parseBuild(14), 14);
      expect(MinVersionService.parseBuild(14.0), 14);
      expect(MinVersionService.parseBuild(1), 1);
      expect(MinVersionService.parseBuild(MinVersionService.maxBuildNumber), MinVersionService.maxBuildNumber);
      expect(MinVersionService.parseBuild(MinVersionService.maxBuildNumber.toDouble()), MinVersionService.maxBuildNumber);
    });
    test('refus : fractionnaire (jamais arrondi), négatif, nul, non fini, trop grand, autres types', () {
      for (final bad in <Object?>[
        14.5, 0.5, 13.999999, -14, -14.0, 0, 0.0, -0.0, double.nan, double.infinity, double.negativeInfinity,
        MinVersionService.maxBuildNumber + 1, (MinVersionService.maxBuildNumber + 1).toDouble(), 1e30,
        '14', 'x', true, null, [14], {'a': 14},
      ]) {
        expect(MinVersionService.parseBuild(bad), isNull, reason: '$bad');
      }
    });
  });

  group('sanitizedMessage', () {
    test('texte non vide de longueur raisonnable, espaces de bord retirés', () {
      expect(MinVersionService.sanitizedMessage('  Mettez à jour  '), 'Mettez à jour');
      expect(MinVersionService.sanitizedMessage('x' * MinVersionService.maxMessageLength), isNotNull);
    });
    test('refus : vide, espaces, trop long (jamais tronqué), autres types', () {
      for (final bad in <Object?>['', '   ', 'x' * (MinVersionService.maxMessageLength + 1), 42, 4.2, true, null, ['a'], {'a': 1}]) {
        expect(MinVersionService.sanitizedMessage(bad), isNull, reason: '$bad');
      }
    });
  });

  group('evaluate avec valeurs numériques', () {
    test('décimal entier = entier ; fractionnaire et valeurs hors bornes = aucune contrainte', () {
      expect(MinVersionService.evaluate({'minBuild': 14.0, 'enforce': true}, 13), MinVersionStatus.updateRequired);
      expect(MinVersionService.evaluate({'minBuild': 14.0, 'enforce': true}, 14), MinVersionStatus.ok);
      for (final bad in <Object?>[14.5, -1, 0, double.nan, double.infinity, 3000000000, '14', null]) {
        expect(MinVersionService.evaluate({'minBuild': bad, 'enforce': true}, 1), MinVersionStatus.ok, reason: '$bad');
      }
    });
  });

  group('check (source injectée)', () {
    // 'desktop' : aucune clé de plateforme (en test, defaultTargetPlatform vaut android).
    Future<MinVersionResult> run(Map<String, dynamic>? doc, {int build = 10, String platform = 'desktop', String role = 'driver'}) =>
        MinVersionService(source: () async => doc).check(role, build: build, platform: platform);
    const unconstrained = (status: MinVersionStatus.ok, message: null, updateUrl: null);

    test('document absent, rôle absent, entrée du rôle invalide : aucune contrainte', () async {
      expect(await run(null), unconstrained);
      expect(await run(<String, dynamic>{}), unconstrained);
      expect(await run({'client': {'minBuild': 99, 'enforce': true}}), unconstrained);
      for (final bad in <Object?>['texte', 42, true, null, [1, 2]]) {
        expect(await run({'driver': bad}), unconstrained, reason: '$bad');
      }
    });

    test('erreur de lecture (hors ligne, permission, délai, inattendue) : aucune contrainte, jamais de blocage', () async {
      final errors = <Object>[
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
        TimeoutException('lent'),
        StateError('inattendue'),
      ];
      for (final e in errors) {
        final r = await MinVersionService(source: () async => throw e).check('driver', build: 1, platform: 'desktop');
        expect(r, unconstrained, reason: '$e');
      }
    });

    test('lecture réussie mais accès au contenu impossible : aucune contrainte', () async {
      final r = await MinVersionService(source: () async => _ExplodingMap()).check('driver', build: 1, platform: 'desktop');
      expect(r, unconstrained);
    });

    test('mise à jour obligatoire avec message et lien valides', () async {
      final r = await run({
        'driver': {'minBuild': 14, 'enforce': true, 'message': ' Mettez à jour ', 'updateUrl': 'https://play.google.com/store/apps/details?id=com.azexpress.app'},
      });
      expect(r.status, MinVersionStatus.updateRequired);
      expect(r.message, 'Mettez à jour');
      expect(r.updateUrl, 'https://play.google.com/store/apps/details?id=com.azexpress.app');
    });

    test('mise à jour recommandée (enforce absent ou faux)', () async {
      expect((await run({'driver': {'minBuild': 14}})).status, MinVersionStatus.updateRecommended);
      expect((await run({'driver': {'minBuild': 14, 'enforce': false}})).status, MinVersionStatus.updateRecommended);
    });

    test('RÉGRESSION M2 : un message invalide ne neutralise jamais une obligation valide', () async {
      for (final bad in <Object?>[123, 4.5, true, ['a'], {'a': 1}, '', '   ', 'x' * 501]) {
        final r = await run({'driver': {'minBuild': 14, 'enforce': true, 'message': bad}});
        expect(r.status, MinVersionStatus.updateRequired, reason: '$bad');
        expect(r.message, isNull, reason: '$bad');
      }
    });

    test('lien invalide : l\'obligation reste, seul le bouton disparaît', () async {
      for (final bad in <Object?>['http://play.google.com/x', 'https://evil.example/x', 'javascript:alert(1)', 5, null]) {
        final r = await run({'driver': {'minBuild': 14, 'enforce': true, 'updateUrl': bad}});
        expect(r.status, MinVersionStatus.updateRequired, reason: '$bad');
        expect(r.updateUrl, isNull, reason: '$bad');
      }
    });

    test('minBuild : entier, décimal entier acceptés ; fractionnaire et invalides = aucune contrainte', () async {
      expect((await run({'driver': {'minBuild': 14, 'enforce': true}})).status, MinVersionStatus.updateRequired);
      expect((await run({'driver': {'minBuild': 14.0, 'enforce': true}})).status, MinVersionStatus.updateRequired);
      expect((await run({'driver': {'minBuild': 10.0, 'enforce': true}})).status, MinVersionStatus.ok); // build 10 suffisant
      for (final bad in <Object?>[14.5, -14, 0, double.nan, double.infinity, 2100000001, '14', true, null]) {
        final r = await run({'driver': {'minBuild': bad, 'enforce': true, 'message': 'm'}});
        expect(r.status, MinVersionStatus.ok, reason: '$bad');
      }
    });

    test('enforce invalide : jamais de blocage, mais la recommandation reste', () async {
      for (final bad in <Object?>['true', 'TRUE', 1, 1.0, 'oui', null, [true], {'a': true}]) {
        final r = await run({'driver': {'minBuild': 14, 'enforce': bad}});
        expect(r.status, MinVersionStatus.updateRecommended, reason: '$bad');
      }
      expect((await run({'driver': {'minBuild': 14, 'enforce': true}})).status, MinVersionStatus.updateRequired);
    });

    test('Android et iOS : clés de plateforme prioritaires, décimal entier accepté, clé invalide ignorée', () async {
      final doc = {'driver': {'minBuild': 5, 'enforce': true, 'minBuildAndroid': 12.0, 'minBuildIos': 3}};
      expect((await run(doc, build: 11, platform: 'android')).status, MinVersionStatus.updateRequired);
      expect((await run(doc, build: 12, platform: 'android')).status, MinVersionStatus.ok);
      expect((await run(doc, build: 11, platform: 'ios')).status, MinVersionStatus.ok);
      expect((await run(doc, build: 2, platform: 'ios')).status, MinVersionStatus.updateRequired);
      expect((await run(doc, build: 4, platform: 'desktop')).status, MinVersionStatus.updateRequired); // minBuild commun
      for (final bad in <Object?>['x', 12.5, -1, 0, double.nan, null]) {
        final d = {'driver': {'minBuild': 5, 'enforce': true, 'minBuildAndroid': bad}};
        expect((await run(d, build: 4, platform: 'android')).status, MinVersionStatus.updateRequired, reason: '$bad'); // repli sur 5
        expect((await run(d, build: 5, platform: 'android')).status, MinVersionStatus.ok, reason: '$bad');
      }
    });

    test('liens par plateforme', () async {
      final doc = {
        'driver': {
          'minBuild': 14, 'enforce': true,
          'updateUrl': 'https://az-express-b0469.web.app/telecharger/',
          'updateUrlAndroid': 'https://play.google.com/store/apps/details?id=com.azexpress.app',
          'updateUrlIos': 'https://apps.apple.com/app/id1',
        },
      };
      expect((await run(doc, platform: 'android')).updateUrl, 'https://play.google.com/store/apps/details?id=com.azexpress.app');
      expect((await run(doc, platform: 'ios')).updateUrl, 'https://apps.apple.com/app/id1');
      expect((await run(doc)).updateUrl, 'https://az-express-b0469.web.app/telecharger/');
    });

    test('build inconnu (0 ou négatif) : jamais de blocage, même obligatoire', () async {
      for (final b in [0, -1]) {
        expect((await run({'driver': {'minBuild': 14, 'enforce': true}}, build: b)).status, MinVersionStatus.ok);
      }
    });

    test('clés non textuelles dans l\'entrée du rôle : ignorées, le reste est exploité', () async {
      final r = await run({'driver': <Object, Object?>{1: 'x', 'minBuild': 14, 'enforce': true}});
      expect(r.status, MinVersionStatus.updateRequired);
    });

    test('un rôle ne lit que sa propre entrée', () async {
      final doc = {'driver': {'minBuild': 14, 'enforce': true}, 'client': {'minBuild': 3}};
      expect((await run(doc, role: 'client')).status, MinVersionStatus.ok);
      expect((await run(doc, role: 'driver')).status, MinVersionStatus.updateRequired);
    });

    test('une seule lecture par vérification', () async {
      var reads = 0;
      final svc = MinVersionService(source: () async {
        reads++;
        return {'driver': {'minBuild': 14}};
      });
      await svc.check('driver', build: 1, platform: 'desktop');
      expect(reads, 1);
    });
  });
}

/// Table dont l'accès lève : simule un contenu inexploitable après une lecture réussie.
class _ExplodingMap extends MapBase<String, dynamic> {
  @override
  dynamic operator [](Object? key) => throw StateError('contenu inexploitable');
  @override
  void operator []=(String key, dynamic value) {}
  @override
  void clear() {}
  @override
  Iterable<String> get keys => const [];
  @override
  dynamic remove(Object? key) => null;
}
