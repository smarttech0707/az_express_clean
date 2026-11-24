import 'dart:io';

import 'package:az_express/legal/legal_renderer.dart';
import 'package:az_express/legal/privacy_content.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mission M2.9 : une seule source (lib/legal/privacy_content.dart) pour les quatre supports de confidentialité.
void main() {
  String read(String p) => File(p).readAsStringSync();
  final privacyHtml = read('web/legal/confidentialite.html');
  final deleteHtml = read('web/legal/delete-account.html');
  final inApp = LegalRenderer.privacyPlainText();

  test('pages web statiques = rendu exact de la source unique (relancer tool/generate_legal_html.dart sinon)', () {
    expect(privacyHtml, LegalRenderer.privacyHtml());
    expect(deleteHtml, LegalRenderer.deleteAccountHtml());
  });

  test('l\'application et la page web Flutter lisent la source unique, sans copie locale', () {
    final profil = read('lib/screens/client/profil_client.dart');
    expect(profil, contains('LegalRenderer.privacyPlainText()'));
    expect(profil, isNot(contains('POLITIQUE DE CONFIDENTIALITÉ — AZ Express\n\nDernière mise à jour : 2026')));
    final page = read('lib/web/pages/privacy_page.dart');
    expect(page, contains('PrivacyContent.sections'));
    expect(page, contains('PrivacyContent.lastUpdated'));
    expect(page, isNot(contains('znm0905')));
    expect(page, isNot(contains('sous 30 jours')));
  });

  group('informations obligatoires, sur chaque support', () {
    const required = <String, List<String>>{
      'données': ['adresse e-mail', 'pièce d\'identité', 'selfie', 'captures d\'écran', 'messages vocaux', 'Firebase Analytics', 'Crashlytics', 'jeton de notification', 'Recherches de lieux'],
      'destinataires': ['Firebase / Google', 'Google (Maps, Places, Routes)', 'OpenStreetMap (Nominatim)', 'FeexPay', 'Anthropic', 'Gemini', 'Apple (iPhone) ou Google (Android)', 'autorités judiciaires'],
      'suppression 30 jours': ['au plus tard 30 jours après votre demande', 'sous réserve des exceptions'],
      'exceptions à confirmer': ['Soldes, transactions du portefeuille', 'Preuves de livraison', 'Journaux de sécurité', 'Sauvegardes et journaux techniques', 'à confirmer', 'pas encore été validées juridiquement'],
      'droits': ['accéder à vos données', 'les corriger', 'vous opposer', 'retirer votre consentement', 'demander la suppression'],
      'contact': ['znm0905@gmail.com', '+225 07 98 05 13 97'],
      'permissions': ['Notifications :', 'Localisation :', 'Caméra :', 'Microphone :', 'Photos et fichiers :'],
    };

    for (final entry in required.entries) {
      for (final phrase in entry.value) {
        test('${entry.key} : « $phrase »', () {
          final inHtml = privacyHtml.replaceAll('&#39;', '\'');
          expect(inHtml, contains(phrase));
          expect(inApp, contains(phrase));
          final pageText = PrivacyContent.sections
              .map((s) => LegalRenderer.plainBlocks(s.blocks))
              .join('\n');
          expect(pageText, contains(phrase));
        });
      }
    }

    test('page de suppression : délai, listes supprimé/conservé et exceptions', () {
      for (final phrase in [
        'au plus tard 30 jours après votre demande',
        ...PrivacyContent.deletedData.map((e) => e.replaceAll('\'', '\'')),
        ...PrivacyContent.keptData,
        'pas encore été validées juridiquement',
      ]) {
        expect(deleteHtml, contains(phrase));
      }
    });

    test('même délai et mêmes listes dans la politique et la page de suppression', () {
      for (final item in [...PrivacyContent.deletedData, ...PrivacyContent.keptData]) {
        expect(privacyHtml, contains(item));
        expect(deleteHtml, contains(item));
      }
    });
  });

  group('règle des 30 jours (M2.11)', () {
    final pageText = PrivacyContent.sections.map((s) => LegalRenderer.plainBlocks(s.blocks)).join('\n');
    final deletePageText = PrivacyContent.deleteSections.map((s) => LegalRenderer.plainBlocks(s.blocks)).join('\n');

    const ordinary =
        'Comptes ordinaires : les données personnelles concernées sont supprimées ou anonymisées au plus tard 30 jours '
        'après votre demande, sous réserve des exceptions ci-dessous.';
    const blocked =
        'Comptes bloqués : si la suppression est impossible (solde de portefeuille, dette, règlement en attente ou '
        'course en cours), la demande est refusée ou suspendue. Après régularisation, vous devez renouveler votre '
        'demande ; le délai de 30 jours court alors à compter de cette nouvelle demande.';
    const partner =
        'Comptes partenaires : la demande fait l\'objet d\'un examen préalable par l\'équipe AZ Express. Le point de '
        'départ du délai de 30 jours pour ces comptes reste à préciser et à valider.';

    test('comptes ordinaires : 30 jours après la demande, sous réserve des exceptions', () {
      for (final text in [pageText, deletePageText, inApp]) {
        expect(text, contains(ordinary));
      }
      expect(privacyHtml, contains('<strong>Comptes ordinaires :</strong>'));
      expect(privacyHtml, contains('<strong>au plus tard 30 jours après votre demande</strong>'));
    });

    test('comptes bloqués : demande refusée ou suspendue, délai compté depuis la nouvelle demande', () {
      for (final text in [pageText, deletePageText, inApp]) {
        expect(text, contains(blocked));
      }
      expect(privacyHtml, contains('<strong>à compter de cette nouvelle demande</strong>'));
      expect(deleteHtml, contains('<strong>à compter de cette nouvelle demande</strong>'));
    });

    test('comptes partenaires : examen préalable, point de départ explicitement non décidé', () {
      for (final text in [pageText, deletePageText, inApp]) {
        expect(text, contains(partner));
      }
      expect(privacyHtml, contains('reste à préciser et à valider'));
      expect(deleteHtml, contains('reste à préciser et à valider'));
    });

    test('les trois règles figurent dans la politique et la page de suppression, en HTML identique', () {
      for (final html in [privacyHtml, deleteHtml]) {
        for (final marker in ['Comptes ordinaires :', 'Comptes bloqués :', 'Comptes partenaires :']) {
          expect(html, contains(marker));
        }
      }
      final block = RegExp(r'<p><strong>Comptes ordinaires.*?valider\.</p>').firstMatch(privacyHtml)!.group(0)!;
      expect(deleteHtml, contains(block));
    });

    test('ancienne formulation retirée', () {
      for (final text in [privacyHtml, deleteHtml, inApp]) {
        expect(text.contains('une fois la demande examinée'), isFalse);
        expect(text.contains('ne court qu\'une fois'), isFalse);
      }
    });
  });

  group('rien d\'inventé', () {
    test('aucune durée de conservation chiffrée autre que les 30 jours décidés', () {
      for (final raw in [privacyHtml, deleteHtml, inApp]) {
        final text = raw.replaceAll('16 ans', ''); // âge minimum, pas une durée de conservation
        expect(RegExp(r'\b\d+\s*(ans?|mois|années)\b').hasMatch(text), isFalse);
        final jours = RegExp(r'(\d+) jours').allMatches(text).map((m) => m[1]).toSet();
        expect(jours.difference({'30'}), isEmpty);
      }
    });

    test('aucune affirmation de conformité juridique', () {
      for (final text in [privacyHtml, deleteHtml, inApp]) {
        expect(RegExp(r'conforme|RGPD|certifi', caseSensitive: false).hasMatch(text), isFalse);
      }
    });

    test('un seul contact, défini à un endroit (pas d\'autre adresse e-mail)', () {
      for (final text in [privacyHtml, deleteHtml, inApp]) {
        final emails = RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+').allMatches(text).map((m) => m[0]).toSet();
        expect(emails, {LegalContact.email});
      }
    });

    test('fournisseurs d\'IA cités : seulement Anthropic et Google (consentement actuel)', () {
      for (final bad in ['OpenAI', 'Mistral', 'DeepSeek', 'Groq']) {
        expect(privacyHtml.contains(bad), isFalse, reason: bad);
      }
    });

    test('exceptions et durées : jamais présentées comme validées', () {
      expect(PrivacyContent.durationsNotice, contains('à confirmer'));
      expect(PrivacyContent.durationsNotice, contains('pas encore été validées juridiquement'));
    });
  });

  test('HTML sûr : balisage échappé, liens présents, pas de script', () {
    expect(privacyHtml, contains('<a href="mailto:znm0905@gmail.com">'));
    expect(privacyHtml, contains('<a href="/delete-account">'));
    expect(deleteHtml, contains('<a href="/confidentialite">'));
    expect(privacyHtml.contains('<script'), isFalse);
    expect(privacyHtml.contains('**'), isFalse);
    expect(deleteHtml.contains('**'), isFalse);
  });
}
