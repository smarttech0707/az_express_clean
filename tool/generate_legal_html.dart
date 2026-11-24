// Régénère web/legal/*.html depuis la source unique lib/legal/privacy_content.dart.
// Usage : dart run tool/generate_legal_html.dart   (test/legal/privacy_content_test.dart vérifie que les fichiers sont à jour)
import 'dart:io';

import 'package:az_express/legal/legal_renderer.dart';

void main() {
  File('web/legal/confidentialite.html').writeAsStringSync(LegalRenderer.privacyHtml());
  File('web/legal/delete-account.html').writeAsStringSync(LegalRenderer.deleteAccountHtml());
  stdout.writeln('web/legal/*.html régénérés');
}
