import 'privacy_content.dart';

/// Rendu des textes de [PrivacyContent] (mission M2.9) : HTML statique et texte brut. Dart pur.
class LegalRenderer {
  LegalRenderer._();

  static const _css =
      ':root{color-scheme:light dark}body{margin:0;font:16px/1.65 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#fff;color:#1b1b1f}main{max-width:820px;margin:0 auto;padding:24px 16px 64px}h1{font-size:1.7rem;margin:.2em 0}h2{font-size:1.15rem;margin:1.8em 0 .4em;color:#c2410c}p,li{margin:.4em 0}a{color:#c2410c}.meta{color:#555;font-size:.9rem}.box{border:1px solid #f3c9a8;background:#fff7f0;border-radius:10px;padding:12px 16px;margin:16px 0}@media(prefers-color-scheme:dark){body{background:#14141a;color:#ececf1}.meta{color:#aaa}.box{background:#241a12;border-color:#5a3a22}h2,a{color:#fb923c}}';

  static const _footer =
      '<p class="meta">AZ Express — Abengourou, Côte d\'Ivoire · <a href="/">Accueil</a> · <a href="/confidentialite">Confidentialité</a> · <a href="/delete-account">Suppression de compte</a></p>';

  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// Échappe, puis applique **gras**, lien e-mail, lien de la page de suppression et lien /confidentialite.
  static String _inline(String raw) {
    var s = _esc(raw);
    s = s.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => '<strong>${m[1]}</strong>');
    s = s.replaceAll(LegalContact.email, '<a href="mailto:${LegalContact.email}">${LegalContact.email}</a>');
    s = s.replaceAll(LegalContact.deleteAccountDisplay,
        '<a href="${LegalContact.deleteAccountPath}">${LegalContact.deleteAccountDisplay}</a>');
    s = s.replaceAll('Politique de confidentialité : /confidentialite',
        '<a href="/confidentialite">Politique de confidentialité</a>');
    return s;
  }

  static String _blocks(List<LegalBlock> blocks) {
    final b = StringBuffer();
    var openOl = false;
    for (final block in blocks) {
      switch (block.kind) {
        case LegalBlockKind.paragraph:
          b.write('<p>${_inline(block.text)}</p>');
        case LegalBlockKind.list:
          b.write('<ul>${block.items.map((i) => '<li>${_inline(i)}</li>').join()}</ul>');
        case LegalBlockKind.callout:
          b.write('<div class="box">${_inline(block.text)}</div>');
      }
    }
    assert(!openOl);
    return b.toString();
  }

  static String _page({
    required String title,
    required String description,
    required String h1,
    required String meta,
    required List<LegalSection> sections,
    String after = '',
  }) {
    final body = sections.map((s) => '<h2>${_esc(s.title)}</h2>${_blocks(s.blocks)}').join();
    return '<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${_esc(title)}</title><meta name="description" content="${_esc(description)}"><meta name="robots" content="index,follow"><style>$_css</style></head><body><main><h1>${_esc(h1)}</h1><p class="meta">${_esc(meta)}</p>$body$after$_footer</main></body></html>';
  }

  static String privacyHtml() => _page(
        title: 'Politique de confidentialité — AZ Express',
        description:
            'Politique de confidentialité de l\'application AZ Express (livraison, courses, marketplace) à Abengourou.',
        h1: 'Politique de confidentialité',
        meta: 'Dernière mise à jour : ${PrivacyContent.lastUpdated}',
        sections: PrivacyContent.sections,
      );

  static String deleteAccountHtml() => _page(
        title: 'Suppression de compte — AZ Express',
        description: 'Comment demander la suppression de votre compte AZ Express et de vos données personnelles.',
        h1: PrivacyContent.deletePageTitle,
        meta: PrivacyContent.deletePageIntro,
        sections: PrivacyContent.deleteSections,
      );

  static String _plainInline(String raw) => raw.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!);

  /// Texte brut d'une liste de sections (page Flutter, écran Profil).
  static String plainSections(List<LegalSection> sections) {
    final b = StringBuffer();
    for (final s in sections) {
      b.writeln(s.title.toUpperCase());
      b.writeln();
      for (final block in s.blocks) {
        switch (block.kind) {
          case LegalBlockKind.paragraph:
          case LegalBlockKind.callout:
            b.writeln(_plainInline(block.text));
          case LegalBlockKind.list:
            for (final i in block.items) {
              b.writeln('• ${_plainInline(i)}');
            }
        }
        b.writeln();
      }
    }
    return b.toString().trimRight();
  }

  /// Texte complet de la politique pour l'écran Profil de l'application.
  static String privacyPlainText() =>
      'POLITIQUE DE CONFIDENTIALITÉ — AZ Express\n\nDernière mise à jour : ${PrivacyContent.lastUpdated}\n\n${plainSections(PrivacyContent.sections)}';

  /// Texte d'une section pour un widget (titre affiché à part).
  static String plainBlocks(List<LegalBlock> blocks) {
    final parts = <String>[];
    for (final block in blocks) {
      switch (block.kind) {
        case LegalBlockKind.paragraph:
        case LegalBlockKind.callout:
          parts.add(_plainInline(block.text));
        case LegalBlockKind.list:
          parts.add(block.items.map((i) => '• ${_plainInline(i)}').join('\n'));
      }
    }
    return parts.join('\n\n');
  }
}
